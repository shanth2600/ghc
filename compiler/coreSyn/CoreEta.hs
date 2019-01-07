{-
Worker/wrapper transformation for type directed etaExpansion.

To be done as part of tidying just before translation to STG.
-}

module CoreEta (arityWorkerWrapper) where

import GhcPrelude

import BasicTypes
import CoreSyn
import CoreSubst
import Literal
import Id
import Panic
import TyCoRep
import UniqSupply
import Unique
import Var
import Outputable

{-
************************************************************************
*                                                                      *
                   Call Arity in the Types
*                                                                      *
************************************************************************
-}

-- ^ Given a top level entity, produce the WorkerWrapper transformed
-- version. This transformation may or may not produce new top level entities
-- depending on its arity.
arityWorkerWrapper :: CoreBind -> UniqSM [CoreBind]
arityWorkerWrapper (NonRec name expr)
  = fmap (uncurry NonRec) <$> arityWorkerWrapper' name expr
arityWorkerWrapper (Rec binds)
  = do { binds' <- mapM (uncurry arityWorkerWrapper') binds
       ; return [Rec (concat binds')] }

-- ^ Change a function binding into a call to its wrapper and the production of
-- a wrapper. The worker/wrapper transformation *only* makes sense for Id's or
-- binders to code.
arityWorkerWrapper'
  :: CoreBndr
  -> CoreExpr
  -> UniqSM [(CoreBndr,CoreExpr)]
arityWorkerWrapper' name expr
  = let arity = idCallArity name in
      case arity >= 1 && isId name of
        True ->
          getUniqueM >>= \uniq ->
            let wname   = mkWorkerId uniq name (idType name)
                worker  = mkArityWrapper name wname expr arity
                wrapper = mkArityWorker  name wname expr arity in
              return [worker,wrapper]
        False -> return [(name,expr)]

-- ^ Create the new type for an extensional function given the arity.
mkArityType :: Type -> Arity -> Type
mkArityType (ForAllTy x ty) _ = ForAllTy x (mkArityType ty 0)
mkArityType (FunTy a b)     _ = FunTildeTy a (mkArityType b 0)
mkArityType ty              _ = ty

-- ^ Given an expression and it's name, generate a new expression with a
-- tilde-lambda type. This is the exact same code, but we have encoded the arity
-- in the type.
mkArityWorker
  :: CoreBndr -> CoreBndr -> CoreExpr -> Arity -> (CoreBndr,CoreExpr)
mkArityWorker name wname expr arity
  = ( wname
    -- ( mkWorkerId uniq name (panic (showSDocUnsafe (debugPprType (mkArityType (idType name) arity))))
    , substExpr (text "eta-worker-subst") substitution expr
    )
  where substitution = extendIdSubst emptySubst name (Var wname)

-- ^ The wrapper does not change the type and will call the newly created worker
-- function.
mkArityWrapper
  :: CoreBndr -> CoreBndr -> CoreExpr -> Arity -> (CoreBndr,CoreExpr)
mkArityWrapper name wname expr arity
  = ( name
    , mkArityWrapper' expr arity wname []
    )

mkArityWrapper'
  :: CoreExpr -> Arity -> CoreBndr -> [CoreExpr] -> CoreExpr
mkArityWrapper' (Lam b e) a w l =
  case isId b of
    True  -> Lam b $ mkArityWrapper' e (a-1) w (Var b : l)
    False -> Lam b $ mkArityWrapper' e a w (Type (TyVarTy b) : l)
mkArityWrapper' _ _ w l = mkApps (Var w) (reverse l)
