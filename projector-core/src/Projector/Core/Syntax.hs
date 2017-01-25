{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
module Projector.Core.Syntax (
    Expr (..)
  , extractAnnotation
  , Name (..)
  , Pattern (..)
  -- * Smart/lazy constructors
  , lit
  , lam
  , lam_
  , var
  , var_
  , app
  , case_
  , con
  , con_
  , list
  , foreign_
  , foreign_'
  -- ** pattern constructors
  , pvar
  , pvar_
  , pcon
  , pcon_
  -- * AST traversals
  , foldFree
  , gatherFree
  , patternBinds
  , mapGround
  , foldlExprM
  , foldlExpr
  , foldrExprM
  , foldrExpr
  ) where


import           Control.Monad.Trans.Cont (cont, runCont)

import           Data.Set (Set)
import qualified Data.Set as S

import           P

import           Projector.Core.Type


-- | The type of Projector expressions.
--
-- The first type parameter, 'l', refers to the type of literal. This is
-- invariant. Literals must have a 'Ground' instance.
--
-- The second type parameter, 'a', refers to the type of annotation,
-- e.g. source location or '()'.
data Expr l a
  = ELit a (Value l)
  | EVar a Name
  | ELam a Name (Type l) (Expr l a)
  | EApp a (Expr l a) (Expr l a)
  | ECon a Constructor TypeName [Expr l a]
  | ECase a (Expr l a) [(Pattern a, Expr l a)]
  | EList a (Type l) [Expr l a]
  | EForeign a Name (Type l)
  deriving (Functor, Foldable, Traversable)

deriving instance (Ground l, Eq a) => Eq (Expr l a)
deriving instance (Ground l, Show a) => Show (Expr l a)
deriving instance (Ground l, Ord a) => Ord (Expr l a)

extractAnnotation :: Expr l a -> a
extractAnnotation e =
  case e of
    ELit a _ ->
      a
    EVar a _ ->
      a
    ELam a _ _ _ ->
      a
    EApp a _ _ ->
      a
    ECon a _ _ _ ->
      a
    ECase a _ _ ->
      a
    EList a _ _ ->
      a
    EForeign a _ _ ->
      a

newtype Name = Name { unName :: Text }
  deriving (Eq, Ord, Show)

-- | Pattern matching. Note that these are necessarily recursive.
data Pattern a
  = PVar a Name
  | PCon a Constructor [Pattern a]
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

-- lazy exprs
lit :: Value l -> Expr l ()
lit =
  ELit ()

lam :: Name -> Type l -> Expr l () -> Expr l ()
lam =
  ELam ()

lam_ :: Text -> Type l -> Expr l () -> Expr l ()
lam_ n =
  lam (Name n)

var :: Name -> Expr l ()
var =
  EVar ()

var_ :: Text -> Expr l ()
var_ t =
  var (Name t)

app :: Expr l () -> Expr l () -> Expr l ()
app =
  EApp ()

case_ :: Expr l () -> [(Pattern (), Expr l ())] -> Expr l ()
case_ =
  ECase ()

con :: Constructor -> TypeName -> [Expr l ()] -> Expr l ()
con =
  ECon ()

con_ :: Text -> Text -> [Expr l ()] -> Expr l ()
con_ c t =
  con (Constructor c) (TypeName t)

list :: Type l -> [Expr l ()] -> Expr l ()
list =
 EList ()

foreign_ :: Name -> Type l -> Expr l ()
foreign_ =
  EForeign ()

foreign_' :: Text -> Type l -> Expr l ()
foreign_' =
  foreign_ . Name

-- lazy pats
pvar :: Name -> Pattern ()
pvar =
  PVar ()

pvar_ :: Text -> Pattern ()
pvar_ =
  pvar . Name

pcon :: Constructor -> [Pattern ()] -> Pattern ()
pcon =
  PCon ()

pcon_ :: Text -> [Pattern ()] -> Pattern ()
pcon_ =
  pcon . Constructor

-- | Strict fold over free variables, including foreign definitions.
foldFree :: (b -> Name -> b) -> b -> Expr l a -> b
foldFree f acc expr =
  go f expr mempty acc
  where
    go f' expr' bound acc' =
      case expr' of
        ELit _ _ ->
          acc'

        EVar _ x ->
          if (S.member x bound) then acc' else f' acc' $! x

        ELam _ n _ body ->
          go f' body (S.insert n $! bound) acc'

        EApp _ a b ->
          go f' b bound $! go f' a bound acc'

        ECon _ _ _ es ->
          foldl' (\a e -> go f' e bound a) acc' es

        ECase _ e pes ->
          let patBinds bnd pat =
                case pat of
                  PVar _ x ->
                    S.insert x $! bnd
                  PCon _ _ pats ->
                    foldl' patBinds bnd pats
          in foldl' (\a (p, ee) -> go f' ee (patBinds bound p) a) (go f' e bound acc') $! pes

        EList _ _ es ->
          foldl' (\a e -> go f' e bound a) acc' es

        EForeign _ x _ ->
          if (S.member x bound) then acc' else f' acc' $! x

-- | Gather all free variables in an expression.
gatherFree :: Expr l a -> Set Name
gatherFree =
  foldFree (flip S.insert) mempty

-- | Gather all names bound by a pattern.
patternBinds :: Pattern a -> Set Name
patternBinds pat =
  case pat of
    PVar _ x ->
      S.singleton x
    PCon _ _ pats ->
      foldl' (<>) mempty (fmap patternBinds pats)

-- | Migrate to a different set of ground types.
mapGround ::
     Ground l
  => Ground m
  => (l -> m)
  -> (Value l -> Value m)
  -> Expr l a
  -> Expr m a
mapGround tmap vmap expr =
  case expr of
    ELit a v ->
      ELit a (vmap v)

    EVar a n ->
      EVar a n

    ELam a n t e ->
      ELam a n (mapGroundType tmap t) (mapGround tmap vmap e)

    EApp a f g ->
      EApp a (mapGround tmap vmap f) (mapGround tmap vmap g)

    ECon a c tn es ->
      ECon a c tn (fmap (mapGround tmap vmap) es)

    ECase a e pes ->
      ECase a (mapGround tmap vmap e) (fmap (fmap (mapGround tmap vmap)) pes)

    EList a t es ->
      EList a (mapGroundType tmap t) (fmap (mapGround tmap vmap) es)

    EForeign a n t ->
      EForeign a n (mapGroundType tmap t)

-- | Bottom-up monadic fold.
foldrExprM :: Monad m => (Expr l a -> b -> m b) -> b -> Expr l a -> m b
foldrExprM f acc expr =
  case expr of
    ELit _ _ ->
      f expr acc

    EVar _ _ ->
      f expr acc

    ELam _ _ _ e -> do
      acc' <- foldrExprM f acc e
      f expr acc'

    EApp _ i j -> do
      acc' <- foldrExprM f acc j
      acc'' <- foldrExprM f acc' i
      f expr acc''

    ECon _ _ _ es -> do
      acc' <- foldrM (flip (foldrExprM f)) acc es
      f expr acc'

    ECase _ e pes -> do
      acc' <- foldrM (flip (foldrExprM f)) acc (fmap snd pes)
      acc'' <- foldrExprM f acc' e
      f expr acc''

    EList _ _ es -> do
      acc' <- foldrM (flip (foldrExprM f)) acc es
      f expr acc'

    EForeign _ _ _ ->
      f expr acc

-- | Bottom-up strict fold.
foldrExpr :: (Expr l a -> b -> b) -> b -> Expr l a -> b
foldrExpr f acc expr =
  runCont (foldrExprM (\e a -> cont (\foo -> foo (f e a))) acc expr) id

-- | Top-down monadic fold.
foldlExprM :: Monad m => (b -> Expr l a -> m b) -> b -> Expr l a -> m b
foldlExprM f acc expr =
  case expr of
    ELit _ _ ->
      f acc expr

    EVar _ _ ->
      f acc expr

    EForeign _ _ _ ->
      f acc expr

    ELam _ _ _ e -> do
      acc' <- f acc expr
      foldlExprM f acc' e

    EApp _ i j -> do
      acc' <- f acc expr
      acc'' <- foldlExprM f acc' i
      foldlExprM f acc'' j

    ECon _ _ _ es -> do
      acc' <- f acc expr
      foldM (foldlExprM f) acc' es

    ECase _ e pes -> do
      acc' <- f acc expr
      acc'' <- foldlExprM f acc' e
      foldM (foldlExprM f) acc'' (fmap snd pes)

    EList _ _ es -> do
      acc' <- f acc expr
      foldM (foldlExprM f) acc' es

-- | Top-down strict fold.
foldlExpr :: (b -> Expr l a -> b) -> b -> Expr l a -> b
foldlExpr f acc =
  flip runCont id . foldlExprM (\a e -> cont (\foo -> foo (f a e))) acc
