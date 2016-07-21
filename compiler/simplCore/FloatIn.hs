{-
(c) The GRASP/AQUA Project, Glasgow University, 1992-1998

************************************************************************
*                                                                      *
\section[FloatIn]{Floating Inwards pass}
*                                                                      *
************************************************************************

The main purpose of @floatInwards@ is floating into branches of a
case, so that we don't allocate things, save them on the stack, and
then discover that they aren't needed in the chosen branch.
-}

{-# LANGUAGE CPP #-}

module FloatIn ( floatInwards ) where

#include "HsVersions.h"

import CoreSyn
import MkCore
import CoreUtils        ( exprIsDupable, exprIsExpandable,
                          exprOkForSideEffects, mkTicks, isJoinBind )
import CoreFVs
import Id               ( isOneShotBndr, idType )
import Var
import Type             ( isUnliftedType )
import VarSet
import Util
import DynFlags
import Outputable
import Data.List( mapAccumL )

{-
Top-level interface function, @floatInwards@.  Note that we do not
actually float any bindings downwards from the top-level.
-}

floatInwards :: DynFlags -> CoreProgram -> CoreProgram
floatInwards dflags = map fi_top_bind
  where
    fi_top_bind (NonRec binder rhs)
      = NonRec binder (fiExpr dflags [] (freeVars rhs))
    fi_top_bind (Rec pairs)
      = Rec [ (b, fiExpr dflags [] (freeVars rhs)) | (b, rhs) <- pairs ]

{-
************************************************************************
*                                                                      *
\subsection{Mail from Andr\'e [edited]}
*                                                                      *
************************************************************************

{\em Will wrote: What??? I thought the idea was to float as far
inwards as possible, no matter what.  This is dropping all bindings
every time it sees a lambda of any kind.  Help! }

You are assuming we DO DO full laziness AFTER floating inwards!  We
have to [not float inside lambdas] if we don't.

If we indeed do full laziness after the floating inwards (we could
check the compilation flags for that) then I agree we could be more
aggressive and do float inwards past lambdas.

Actually we are not doing a proper full laziness (see below), which
was another reason for not floating inwards past a lambda.

This can easily be fixed.  The problem is that we float lets outwards,
but there are a few expressions which are not let bound, like case
scrutinees and case alternatives.  After floating inwards the
simplifier could decide to inline the let and the laziness would be
lost, e.g.

\begin{verbatim}
let a = expensive             ==> \b -> case expensive of ...
in \ b -> case a of ...
\end{verbatim}
The fix is
\begin{enumerate}
\item
to let bind the algebraic case scrutinees (done, I think) and
the case alternatives (except the ones with an
unboxed type)(not done, I think). This is best done in the
SetLevels.hs module, which tags things with their level numbers.
\item
do the full laziness pass (floating lets outwards).
\item
simplify. The simplifier inlines the (trivial) lets that were
 created but were not floated outwards.
\end{enumerate}

With the fix I think Will's suggestion that we can gain even more from
strictness by floating inwards past lambdas makes sense.

We still gain even without going past lambdas, as things may be
strict in the (new) context of a branch (where it was floated to) or
of a let rhs, e.g.
\begin{verbatim}
let a = something            case x of
in case x of                   alt1 -> case something of a -> a + a
     alt1 -> a + a      ==>    alt2 -> b
     alt2 -> b

let a = something           let b = case something of a -> a + a
in let b = a + a        ==> in (b,b)
in (b,b)
\end{verbatim}
Also, even if a is not found to be strict in the new context and is
still left as a let, if the branch is not taken (or b is not entered)
the closure for a is not built.

************************************************************************
*                                                                      *
\subsection{Main floating-inwards code}
*                                                                      *
************************************************************************
-}

type FreeVarSet  = DIdSet
type BoundVarSet = DIdSet

data FloatInBind = FB BoundVarSet FreeVarSet FloatBind
        -- The FreeVarSet is the free variables of the binding.  In the case
        -- of recursive bindings, the set doesn't include the bound
        -- variables.

type FloatInBinds = [FloatInBind]
        -- In reverse dependency order (innermost binder first)

fiExpr :: DynFlags
       -> FloatInBinds      -- Binds we're trying to drop
                            -- as far "inwards" as possible
       -> CoreExprWithFVs   -- Input expr
       -> CoreExpr          -- Result

fiExpr _ to_drop (_, AnnLit lit)     = ASSERT( null to_drop ) Lit lit
fiExpr _ to_drop (_, AnnType ty)     = ASSERT( null to_drop ) Type ty
fiExpr _ to_drop (_, AnnVar v)       = wrapFloats to_drop (Var v)
fiExpr _ to_drop (_, AnnCoercion co) = wrapFloats to_drop (Coercion co)
fiExpr dflags to_drop (_, AnnCast expr (co_ann, co))
  = wrapFloats (drop_here ++ co_drop) $
    Cast (fiExpr dflags e_drop expr) co
  where
    [drop_here, e_drop, co_drop]
      = sepBindsByDropPoint dflags False False
          [freeVarsOf expr, freeVarsOfAnn co_ann]
          (freeVarsOfType expr `unionDVarSet` freeVarsOfTypeAnn co_ann)
          to_drop

{-
Applications: we do float inside applications, mainly because we
need to get at all the arguments.  The next simplifier run will
pull out any silly ones.
-}

fiExpr dflags to_drop ann_expr@(_,AnnApp {})
  = mkTicks ticks $ wrapFloats drop_here $ wrapFloats extra_drop $
    mkApps (fiExpr dflags fun_drop ann_fun)
           (zipWith (fiExpr dflags) arg_drops ann_args)
  where
    (ann_fun, ann_args, ticks) = collectAnnArgsTicks tickishFloatable ann_expr
    (extra_fvs, arg_fvs) = mapAccumL mk_arg_fvs emptyDVarSet ann_args

    mk_arg_fvs :: FreeVarSet -> CoreExprWithFVs -> (FreeVarSet, FreeVarSet)
    mk_arg_fvs extra_fvs ann_arg
      | noFloatIntoRhs ann_arg
      = (extra_fvs `unionDVarSet` freeVarsOf ann_arg, emptyDVarSet)
      | otherwise
      = (extra_fvs, freeVarsOf ann_arg)

    drop_here : extra_drop : fun_drop : arg_drops
      = sepBindsByDropPoint dflags False True -- Note [Join points]
          (extra_fvs : freeVarsOf ann_fun : arg_fvs)
          (freeVarsOfType ann_fun `unionDVarSet`
           mapUnionDVarSet freeVarsOfType ann_args)
          to_drop

{-
Note [Do not destroy the let/app invariant]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Watch out for
   f (x +# y)
We don't want to float bindings into here
   f (case ... of { x -> x +# y })
because that might destroy the let/app invariant, which requires
unlifted function arguments to be ok-for-speculation.

Note [Floating in past a lambda group]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
* We must be careful about floating inside a value lambda.
  That risks losing laziness.
  The float-out pass might rescue us, but then again it might not.

* We must be careful about type lambdas too.  At one time we did, and
  there is no risk of duplicating work thereby, but we do need to be
  careful.  In particular, here is a bad case (it happened in the
  cichelli benchmark:
        let v = ...
        in let f = /\t -> \a -> ...
           ==>
        let f = /\t -> let v = ... in \a -> ...
  This is bad as now f is an updatable closure (update PAP)
  and has arity 0.

* Hack alert!  We only float in through one-shot lambdas,
  not (as you might guess) through lone big lambdas.
  Reason: we float *out* past big lambdas (see the test in the Lam
  case of FloatOut.floatExpr) and we don't want to float straight
  back in again.

  It *is* important to float into one-shot lambdas, however;
  see the remarks with noFloatIntoRhs.

So we treat lambda in groups, using the following rule:

 Float in if (a) there is at least one Id,
         and (b) there are no non-one-shot Ids

 Otherwise drop all the bindings outside the group.

This is what the 'go' function in the AnnLam case is doing.

Urk! if all are tyvars, and we don't float in, we may miss an
      opportunity to float inside a nested case branch
-}

fiExpr dflags to_drop lam@(_, AnnLam _ _)
  | okToFloatInside bndrs       -- Float in
     -- NB: Must line up with noFloatIntoRhs (AnnLam...); see Trac #7088
  = mkLams bndrs (fiExpr dflags to_drop body)

  | otherwise           -- Dump it all here
  = wrapFloats to_drop (mkLams bndrs (fiExpr dflags [] body))

  where
    (bndrs, body) = collectAnnBndrs lam

{-
We don't float lets inwards past an SCC.
        ToDo: keep info on current cc, and when passing
        one, if it is not the same, annotate all lets in binds with current
        cc, change current cc to the new one and float binds into expr.
-}

fiExpr dflags to_drop (_, AnnTick tickish expr)
  | tickish `tickishScopesLike` SoftScope
  = Tick tickish (fiExpr dflags to_drop expr)

  | otherwise -- Wimp out for now - we could push values in
  = wrapFloats to_drop (Tick tickish (fiExpr dflags [] expr))

{-
For @Lets@, the possible ``drop points'' for the \tr{to_drop}
bindings are: (a)~in the body, (b1)~in the RHS of a NonRec binding,
or~(b2), in each of the RHSs of the pairs of a @Rec@.

Note that we do {\em weird things} with this let's binding.  Consider:
\begin{verbatim}
let
    w = ...
in {
    let v = ... w ...
    in ... v .. w ...
}
\end{verbatim}
Look at the inner \tr{let}.  As \tr{w} is used in both the bind and
body of the inner let, we could panic and leave \tr{w}'s binding where
it is.  But \tr{v} is floatable further into the body of the inner let, and
{\em then} \tr{w} will also be only in the body of that inner let.

So: rather than drop \tr{w}'s binding here, we add it onto the list of
things to drop in the outer let's body, and let nature take its
course.

Note [extra_fvs (1): avoid floating into RHS]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider let x=\y....t... in body.  We do not necessarily want to float
a binding for t into the RHS, because it'll immediately be floated out
again.  (It won't go inside the lambda else we risk losing work.)
In letrec, we need to be more careful still. We don't want to transform
        let x# = y# +# 1#
        in
        letrec f = \z. ...x#...f...
        in ...
into
        letrec f = let x# = y# +# 1# in \z. ...x#...f... in ...
because now we can't float the let out again, because a letrec
can't have unboxed bindings.

So we make "extra_fvs" which is the rhs_fvs of such bindings, and
arrange to dump bindings that bind extra_fvs before the entire let.

Note [extra_fvs (2): free variables of rules]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider
  let x{rule mentioning y} = rhs in body
Here y is not free in rhs or body; but we still want to dump bindings
that bind y outside the let.  So we augment extra_fvs with the
idRuleAndUnfoldingVars of x.  No need for type variables, hence not using
idFreeVars.
-}

fiExpr dflags to_drop (_,AnnLet (AnnNonRec id rhs) body)
  = fiExpr dflags new_to_drop body
  where
    body_fvs = freeVarsOf body `delDVarSet` id
    rhs_fvs  = freeVarsOf rhs

    rule_fvs = idRuleAndUnfoldingVarsDSet id        -- See Note [extra_fvs (2): free variables of rules]
    extra_fvs | noFloatIntoRhs rhs = rule_fvs `unionDVarSet` freeVarsOf rhs
              | otherwise          = rule_fvs
        -- See Note [extra_fvs (1): avoid floating into RHS]
        -- No point in floating in only to float straight out again
        -- Ditto ok-for-speculation unlifted RHSs

    [shared_binds, extra_binds, rhs_binds, body_binds]
        = sepBindsByDropPoint dflags False False
            [extra_fvs, rhs_fvs, body_fvs]
            (freeVarsOfType rhs `unionDVarSet` freeVarsOfType body)
            to_drop

    new_to_drop = body_binds ++                         -- the bindings used only in the body
                  [FB (unitDVarSet id) rhs_fvs'
                      (FloatLet (NonRec id rhs'))] ++   -- the new binding itself
                  extra_binds ++                        -- bindings from extra_fvs
                  shared_binds                          -- the bindings used both in rhs and body

        -- Push rhs_binds into the right hand side of the binding
    rhs'     = fiExpr dflags rhs_binds rhs
    rhs_fvs' = rhs_fvs `unionDVarSet` floatedBindsFVs rhs_binds `unionDVarSet` rule_fvs
                        -- Don't forget the rule_fvs; the binding mentions them!

fiExpr dflags to_drop (_,AnnLet (AnnRec bindings) body)
  = fiExpr dflags new_to_drop body
  where
    (ids, rhss) = unzip bindings
    rhss_fvs = map freeVarsOf rhss
    body_fvs = freeVarsOf body

        -- See Note [extra_fvs (1,2)]
    rule_fvs = mapUnionDVarSet idRuleAndUnfoldingVarsDSet ids
    extra_fvs = rule_fvs `unionDVarSet`
                unionDVarSets [ freeVarsOf rhs | rhs@(_, rhs') <- rhss
                              , noFloatIntoExpr rhs' ]

    (shared_binds:extra_binds:body_binds:rhss_binds)
        = sepBindsByDropPoint dflags False False
            (extra_fvs:body_fvs:rhss_fvs)
            (freeVarsOfType body `unionDVarSet` mapUnionDVarSet freeVarsOfType rhss)
            to_drop

    new_to_drop = body_binds ++         -- the bindings used only in the body
                  [FB (mkDVarSet ids) rhs_fvs'
                      (FloatLet (Rec (fi_bind rhss_binds bindings)))] ++
                                        -- The new binding itself
                  extra_binds ++        -- Note [extra_fvs (1,2)]
                  shared_binds          -- Used in more than one place

    rhs_fvs' = unionDVarSets rhss_fvs `unionDVarSet`
               unionDVarSets (map floatedBindsFVs rhss_binds) `unionDVarSet`
               rule_fvs         -- Don't forget the rule variables!

    -- Push rhs_binds into the right hand side of the binding
    fi_bind :: [FloatInBinds]       -- one per "drop pt" conjured w/ fvs_of_rhss
            -> [(Id, CoreExprWithFVs)]
            -> [(Id, CoreExpr)]

    fi_bind to_drops pairs
      = [ (binder, fiExpr dflags to_drop rhs)
        | ((binder, rhs), to_drop) <- zipEqual "fi_bind" pairs to_drops ]

{-
For @Case@, the possible ``drop points'' for the \tr{to_drop}
bindings are: (a)~inside the scrutinee, (b)~inside one of the
alternatives/default [default FVs always {\em first}!].

Floating case expressions inward was added to fix Trac #5658: strict bindings
not floated in. In particular, this change allows array indexing operations,
which have a single DEFAULT alternative without any binders, to be floated
inward. SIMD primops for unpacking SIMD vectors into an unboxed tuple of unboxed
scalars also need to be floated inward, but unpacks have a single non-DEFAULT
alternative that binds the elements of the tuple. We now therefore also support
floating in cases with a single alternative that may bind values.
-}

fiExpr dflags to_drop (_, AnnCase scrut case_bndr _ [(con,alt_bndrs,rhs)])
  | isUnliftedType (idType case_bndr)
  , exprOkForSideEffects (deAnnotate scrut)
      -- See PrimOp, Note [PrimOp can_fail and has_side_effects]
  = wrapFloats shared_binds $
    fiExpr dflags (case_float : rhs_binds) rhs
  where
    case_float = FB (mkDVarSet (case_bndr : alt_bndrs)) scrut_fvs
                    (FloatCase scrut' case_bndr con alt_bndrs)
    scrut' = fiExpr dflags scrut_binds scrut
    [shared_binds, scrut_binds, rhs_binds]
       = sepBindsByDropPoint dflags False False
           [scrut_fvs, rhs_fvs]
           (freeVarsOfType scrut `unionDVarSet` rhs_ty_fvs)
           to_drop
    rhs_fvs    = freeVarsOf rhs `delDVarSetList` (case_bndr : alt_bndrs)
    rhs_ty_fvs = freeVarsOfType rhs `delDVarSetList` (case_bndr : alt_bndrs)
    scrut_fvs  = freeVarsOf scrut

fiExpr dflags to_drop (_, AnnCase scrut case_bndr ty alts)
  = wrapFloats drop_here1 $
    wrapFloats drop_here2 $
    Case (fiExpr dflags scrut_drops scrut) case_bndr ty
         (zipWith fi_alt alts_drops_s alts)
  where
        -- Float into the scrut and alts-considered-together just like App
    [drop_here1, scrut_drops, alts_drops]
       = sepBindsByDropPoint dflags False False
           [scrut_fvs, all_alts_fvs]
           (freeVarsOfType scrut `unionDVarSet` all_alts_ty_fvs)
           to_drop

        -- Float into the alts with the is_case flag set
    (drop_here2 : alts_drops_s)
      = sepBindsByDropPoint dflags True False alts_fvs all_alts_ty_fvs alts_drops

    scrut_fvs       = freeVarsOf scrut
    alts_fvs        = map alt_fvs alts
    all_alts_fvs    = unionDVarSets alts_fvs
    alts_ty_fvs     = map alt_ty_fvs alts
    all_alts_ty_fvs = unionDVarSets alts_ty_fvs
    alt_fvs (_con, args, rhs)
      = foldl delDVarSet (freeVarsOf rhs)     (case_bndr:args)
    alt_ty_fvs (_con, args, rhs)
      = foldl delDVarSet (freeVarsOfType rhs) (case_bndr:args)
                                -- Delete case_bndr and args from free vars of rhs
                                -- to get free vars of alt

    fi_alt to_drop (con, args, rhs) = (con, args, fiExpr dflags to_drop rhs)

okToFloatInside :: [Var] -> Bool
okToFloatInside bndrs = all ok bndrs
  where
    ok b = not (isId b) || isOneShotBndr b
    -- Push the floats inside there are no non-one-shot value binders

noFloatIntoRhs :: CoreExprWithFVs -> Bool
-- ^ True if it's a bad idea to float bindings into this RHS
-- Preconditio:  rhs :: rhs_ty
noFloatIntoRhs rhs@(_, rhs')
  =  isUnliftedType rhs_ty   -- See Note [Do not destroy the let/app invariant]
  || noFloatIntoExpr rhs'
  where
    rhs_ty = exprTypeFV rhs

noFloatIntoExpr :: CoreExprWithFVs' -> Bool
noFloatIntoExpr (AnnLam bndr e)
   = not (okToFloatInside (bndr:bndrs))
     -- NB: Must line up with fiExpr (AnnLam...); see Trac #7088
   where
     (bndrs, _) = collectAnnBndrs e
        -- IMPORTANT: don't say 'True' for a RHS with a one-shot lambda at the top.
        -- This makes a big difference for things like
        --      f x# = let x = I# x#
        --             in let j = \() -> ...x...
        --                in if <condition> then normal-path else j ()
        -- If x is used only in the error case join point, j, we must float the
        -- boxing constructor into it, else we box it every time which is very bad
        -- news indeed.

noFloatIntoExpr rhs = exprIsExpandable (deAnnotate' rhs)
       -- We'd just float right back out again...
       -- Should match the test in SimplEnv.doFloatFromRhs

{-
************************************************************************
*                                                                      *
\subsection{@sepBindsByDropPoint@}
*                                                                      *
************************************************************************

This is the crucial function.  The idea is: We have a wad of bindings
that we'd like to distribute inside a collection of {\em drop points};
insides the alternatives of a \tr{case} would be one example of some
drop points; the RHS and body of a non-recursive \tr{let} binding
would be another (2-element) collection.

So: We're given a list of sets-of-free-variables, one per drop point,
and a list of floating-inwards bindings.  If a binding can go into
only one drop point (without suddenly making something out-of-scope),
in it goes.  If a binding is used inside {\em multiple} drop points,
then it has to go in a you-must-drop-it-above-all-these-drop-points
point.

But, with coercions appearing in types, there is a complication: we
might be floating in a "strict let" -- that is, a case. Case expressions
mention their return type. We absolutely can't float a coercion binding
inward to the point that the type of the expression it's about to wrap
mentions the coercion. So we include the union of the sets of free variables
of the types of all the drop points involved. If any of the floaters
bind a coercion variable mentioned in any of the types, that binder must
be dropped right away.

We have to maintain the order on these drop-point-related lists.

Note [Join points]
~~~~~~~~~~~~~~~~~~

Generally, we don't need to worry about join points - there are places we're
not allowed to float them, but since they can't have occurrences in those
places, we're not tempted. The exception is at an invocation of the join point
itself:

  j x y z

If we traverse this as usual, we might attempt to drop j right at its only use
(very common if j is recursive). So at an application, we stop ourselves from
floating join points at all.
-}

sepBindsByDropPoint
    :: DynFlags
    -> Bool             -- True <=> is case expression
    -> Bool             -- True <=> drop join points; see Note [Join points]
    -> [FreeVarSet]         -- One set of FVs per drop point
    -> FreeVarSet           -- Vars free in all the types of the drop points
    -> FloatInBinds         -- Candidate floaters
    -> [FloatInBinds]      -- FIRST one is bindings which must not be floated
                            -- inside any drop point; the rest correspond
                            -- one-to-one with the input list of FV sets

-- Every input floater is returned somewhere in the result;
-- none are dropped, not even ones which don't seem to be
-- free in *any* of the drop-point fvs.  Why?  Because, for example,
-- a binding (let x = E in B) might have a specialised version of
-- x (say x') stored inside x, but x' isn't free in E or B.

type DropBox = (FreeVarSet, FloatInBinds)

sepBindsByDropPoint _ _is_case _stop_joins drop_pts _ty_fvs []
  = [] : [[] | _ <- drop_pts]   -- cut to the chase scene; it happens

sepBindsByDropPoint dflags is_case stop_joins drop_pts ty_fvs floaters
  = go floaters (map (\fvs -> (fvs, [])) (emptyDVarSet : drop_pts))
  where
    go :: FloatInBinds -> [DropBox] -> [FloatInBinds]
        -- The *first* one in the argument list is the drop_here set
        -- The FloatInBinds in the lists are in the reverse of
        -- the normal FloatInBinds order; that is, they are the right way round!

    go [] drop_boxes = map (reverse . snd) drop_boxes

    go (bind_w_fvs@(FB bndrs bind_fvs bind) : binds) drop_boxes@(here_box : fork_boxes)
        = go binds new_boxes
        where
          -- "here" means the group of bindings dropped at the top of the fork

          (used_here : used_in_flags) = [ fvs `intersectsDVarSet` bndrs
                                        | (fvs, _) <- drop_boxes]
          used_in_ty = ty_fvs `intersectsDVarSet` bndrs

          drop_here = used_here || not can_push || used_in_ty
                                || (stop_joins && is_join)

                -- For case expressions we duplicate the binding if it is
                -- reasonably small, and if it is not used in all the RHSs
                -- This is good for situations like
                --      let x = I# y in
                --      case e of
                --        C -> error x
                --        D -> error x
                --        E -> ...not mentioning x...

          n_alts      = length used_in_flags
          n_used_alts = count id used_in_flags -- returns number of Trues in list.

          can_push = n_used_alts == 1           -- Used in just one branch
                   || (is_case &&               -- We are looking at case alternatives
                       n_used_alts > 1 &&       -- It's used in more than one
                       n_used_alts < n_alts &&  -- ...but not all
                       floatIsDupable dflags bind) -- and we can duplicate the binding

          is_join = case bind of FloatLet b   -> isJoinBind b
                                 FloatCase {} -> False

          new_boxes | drop_here = (insert here_box : fork_boxes)
                    | otherwise = (here_box : new_fork_boxes)

          new_fork_boxes = zipWithEqual "FloatIn.sepBinds" insert_maybe fork_boxes used_in_flags

          insert :: DropBox -> DropBox
          insert (fvs,drops) = (fvs `unionDVarSet` bind_fvs, bind_w_fvs:drops)

          insert_maybe box True  = insert box
          insert_maybe box False = box

    go _ _ = panic "sepBindsByDropPoint/go"


floatedBindsFVs :: FloatInBinds -> FreeVarSet
floatedBindsFVs binds = mapUnionDVarSet fbFVs binds

fbFVs :: FloatInBind -> DVarSet
fbFVs (FB _ fvs _) = fvs

wrapFloats :: FloatInBinds -> CoreExpr -> CoreExpr
-- Remember FloatInBinds is in *reverse* dependency order
wrapFloats []               e = e
wrapFloats (FB _ _ fl : bs) e = wrapFloats bs (wrapFloat fl e)

floatIsDupable :: DynFlags -> FloatBind -> Bool
floatIsDupable dflags (FloatCase scrut _ _ _) = exprIsDupable dflags scrut
floatIsDupable dflags (FloatLet (Rec prs))    = all (exprIsDupable dflags . snd) prs
floatIsDupable dflags (FloatLet (NonRec _ r)) = exprIsDupable dflags r
