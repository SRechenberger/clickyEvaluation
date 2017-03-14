module TypeChecker where

import Prelude (class Show, Unit, (&&), (==), (/=), (>>=), map, ($), pure, (<*>), (<$>), bind, const, otherwise, show, (+), div, mod, flip, (<>), (>), (-), (>>>), (<<<))
import Control.Monad.Except.Trans (ExceptT, runExceptT, throwError, catchError)
import Control.Monad.Except as Ex
import Control.Monad.State (State, evalState, runState, put, get)
import Control.Monad.RWS.Trans (RWST)
import Control.Monad.RWS (ask, evalRWST)
import Data.Bifunctor (rmap)
import Control.Apply (lift2)
import Control.Bind (ifM)
import Data.Either (Either(Left, Right))
import Data.List (List(..), filter, delete, concatMap, unzip, foldM, (:), zip, singleton, length, concat, (!!))
import Data.Array as Array
import Data.Map as Map
import Data.Map (Map, insert, lookup, empty)
import Data.Tuple (Tuple(Tuple), snd, fst)
import Data.Traversable (traverse)
import Data.Set as Set
import Data.Foldable (intercalate, foldr, foldMap, elem)
import Data.Maybe (Maybe(..), fromMaybe, fromJust, maybe)
import Partial.Unsafe (unsafePartial, unsafeCrashWith)
import Data.String (fromCharArray)
import Data.Char as Char

import AST

data Scheme = Forall (List TVar) Type

instance showScheme :: Show Scheme where
  show (Forall a b) = "Forall (" <> show a <> ") " <> show b

-- | Pretty print a type scheme.
ppScheme :: Scheme -> String
ppScheme (Forall Nil t) = prettyPrintType t
ppScheme (Forall tvars t) = "forall "
                         <> intercalate " " tvars
                         <> ". "
                         <> prettyPrintType t

type TVarMapping = Tuple TVar Scheme

type TVarMappings = List TVarMapping

data TypeEnv = TypeEnv (Map.Map TVar Scheme)

-- | Create an empty type environment.
emptyTypeEnv :: TypeEnv
emptyTypeEnv = TypeEnv Map.empty

-- | Pretty print a type environment.
-- | Example output:
-- | ```
-- | Type environment:
-- |   not : Bool -> Bool,
-- |   id : forall t_2. t_2 -> t_2
-- | ```
ppTypeEnv :: TypeEnv -> String
ppTypeEnv (TypeEnv env) = "Type environment:\n" <>
  (map ppTVAndScheme >>> intercalate ",\n")
  (Map.toList env)
  where ppTVAndScheme (Tuple tv scheme) = "\t" <> tv <> " : " <> ppScheme scheme

instance showTypeEnv :: Show TypeEnv where
  show (TypeEnv a) = show a

data Unique = Unique { count :: Int }

type Infer a = ExceptT TypeError (State Unique) a

---------------------------------------------------------------------------------------------------
-- | Refactoring into 2-phase type process                                                       --
---------------------------------------------------------------------------------------------------

-- | The type `Bool`.
boolType :: Type
boolType = TypCon "Bool"

-- | The type `Char`.
charType :: Type
charType = TypCon "Char"

-- | The type `Int`.
intType :: Type
intType = TypCon "Int"

-- | The type `Int -> Int`.
intToIntType :: Type
intToIntType = intType `TypArr` intType

-- | The type `Int -> Int -> Int`.
intToIntToIntType :: Type
intToIntToIntType = intType `TypArr` intToIntType

-- | Type constraints.
data Constraint = Constraint Type Type Index
type Constraints = List Constraint

-- | Constraints are substitutable.
instance substitutableConstraint :: Substitutable Constraint where
    apply s (Constraint t1 t2 idx) = Constraint (apply s t1) (apply s t2) idx
    ftv (Constraint t1 t2 idx) = ftv t1 `Set.union` ftv t2

ppConstraints :: Constraints -> String
ppConstraints constraints = "Constraints:\n" <> (map ppConstraint >>> intercalate ",\n") constraints
  where ppConstraint (Constraint t1 t2 idx) = "\t"
                                  <> prettyPrintType t1
                                  <> " is "
                                  <> prettyPrintType t2
                                  <> " for node "
                                  <> show idx

type InferNew a = (RWST
  TypeEnv               -- ^ Read from the type environment.
  Unit
  Unique                -- ^ The infer state.
  (Ex.Except TypeError) -- ^ Catch type errors.
  a)

-- | Choose a fresh type variable name.
freshTVarNew :: InferNew TVar
freshTVarNew = do
    Unique s <- get
    put (Unique { count: (s.count + 1) })
    pure $ "t_" <> show s.count

-- | Choose a fresh type variable.
freshNew :: InferNew Type
freshNew = TypVar <$> freshTVarNew

-- | Create a monotype from the given type scheme.
instantiateNew :: Scheme -> InferNew Type
instantiateNew (Forall as t) = do
  as' <- traverse (const freshNew) as
  let s = Map.fromFoldable $ zip as as'
  pure $ apply s t

-- | Lookup a type in the type environment.
lookupEnvNew :: TVar -> InferNew Type
lookupEnvNew tvar = do
  TypeEnv env <- ask
  case Map.lookup tvar env of
    Nothing -> Ex.throwError $ UnboundVariable tvar
    Just scheme  -> instantiateNew scheme >>= pure

-- | Run the type inference and catch type errors. Note that the only possible errors are:
-- |   * `UnboundVariable`
-- |   * `NoInstanceOfEnum`
-- |   * `UnknownError`
-- | All other errors can only be encountered during the constraint solving phase.
runInferNew :: TypeEnv -> InferNew (Tuple Type Constraints) -> Either TypeError Constraints
runInferNew env m = rmap (\res -> snd $ fst res) (Ex.runExcept $ evalRWST m env initUnique)

-- | Given an indexed expression, add a type constraint using the given type and expression index.
returnWithConstraint :: IndexedTypeTree -> Type -> InferNew (Tuple Type Constraints)
returnWithConstraint expr t = do
    tv <- freshNew
    pure $ Tuple tv (singleton $ Constraint tv t (getIndex expr))

-- | Traverse the given type tree and collect type constraints.
inferNew :: IndexedTypeTree -> InferNew (Tuple Type Constraints)
inferNew ex = case ex of
  Atom _ atom@(Bool _) -> returnWithConstraint ex boolType
  Atom _ atom@(Char _) -> returnWithConstraint ex charType
  Atom _ atom@(AInt _) -> returnWithConstraint ex intType
  Atom _ atom@(Name name) -> case name of
    -- Built-in functions.
    "mod" -> returnWithConstraint ex intToIntToIntType
    "div" -> returnWithConstraint ex intToIntToIntType
    -- Try to find the variable name in the type environment.
    _     -> do t <- lookupEnvNew name
                pure $ Tuple t Nil
  _ -> Ex.throwError $ UnknownError "Not yet implemented."

-- | Collect the substitutions by working through the constraints. The substitution represents
-- | the solution to the constraint solving problem.
data Unifier = Unifier Subst Constraints

-- | Collect the substitutions in the unifier and catch occurring type errors.
runSolve :: Constraints -> Either TypeError Subst
runSolve constraints = Ex.runExcept $ solver (Unifier nullSubst constraints)

-- | Bind the given type variable to the given type and return the resulting substitution.
bindTVar ::  TVar -> Type -> Ex.Except TypeError Subst
bindTVar tv t
  | t == (TypVar tv) = pure $ nullSubst
  | occursCheck tv t = Ex.throwError $ normalizeTypeError $ InfiniteType tv t
  | otherwise = pure $ Map.singleton tv t

-- | Try to unify the given types and return the resulting substitution or the occurring type
-- | error.
unifies :: Type -> Type -> Ex.Except TypeError Subst
unifies (TypArr l1 r1) (TypArr l2 r2) = do
  s1 <- unifies l1 l2
  s2 <- unifies (apply s1 r1) (apply s1 r2)
  pure $ s2 `compose` s1
unifies (TypVar tv) t = tv `bindTVar` t
unifies t (TypVar tv) = tv `bindTVar` t
unifies (TypCon c1) (TypCon c2) | c1 == c2 = pure nullSubst
unifies t1 t2 = Ex.throwError $ normalizeTypeError $ UnificationFail t1 t2

-- | Try to unify the given AD types and return the resulting substitution or the occurring type
-- | error.
unifiesAD :: AD -> AD -> Ex.Except TypeError Subst
unifiesAD (TList l1) (TList l2) = unifies l1 l2
unifiesAD (TTuple (a:as)) (TTuple (b:bs)) = do
  s1 <- unifiesAD (TTuple as) (TTuple bs)
  s2 <- unifies a b
  pure $ s1 `compose` s2
unifiesAD (TTuple Nil) (TTuple Nil) = pure nullSubst
unifiesAD t1 t2 = throwError $ normalizeTypeError $ UnificationFail (AD t1) (AD t2)

-- | Try to solve the constraints.
solver :: Unifier -> Ex.Except TypeError Subst
solver (Unifier subst constraints) = case constraints of
  Nil -> pure subst
  ((Constraint t1 t2 idx) : rest) -> do
    subst1 <- unifies t1 t2
    solver (Unifier (subst1 `compose` subst) (apply subst1 rest))

---------------------------------------------------------------------------------------------------

type Subst = Map.Map TVar Type

-- | Pretty print a substitution.
-- | Example output:
-- | ```
-- | Substitution:
-- |   t0 ~ Int,
-- |   t1 ~ Int -> Int
-- | ```
ppSubst :: Subst -> String
ppSubst subst = "Substitutions:\n" <>
  (map ppTVAndType >>> intercalate ",\n")
  (Map.toList subst)
  where ppTVAndType (Tuple tv t) = "\t" <> tv <> " ~ " <> prettyPrintType t

class Substitutable a where
  apply :: Subst -> a -> a
  ftv   :: a -> Set.Set TVar

instance subScheme :: Substitutable Scheme where
    apply s (Forall as t)   = Forall as $ apply s' t
                              where s' = foldr Map.delete s as
    ftv (Forall as t) = (ftv t) `Set.difference` Set.fromFoldable as

instance subType :: Substitutable Type where
   apply _ UnknownType = UnknownType
   apply _ (TypCon a) = TypCon a
   apply s t@(TypVar a) = fromMaybe t $ Map.lookup a s
   apply s (TypArr t1 t2) =  TypArr (apply s t1) (apply s t2)
   apply s (AD a) = AD (apply s a)
   apply _ (TypeError err) = TypeError err

   ftv UnknownType = Set.empty
   ftv (TypCon  _)         = Set.empty
   ftv (TypVar a)       = Set.singleton a
   ftv (TypArr t1 t2) =  Set.union (ftv t1) (ftv t2)
   ftv (AD a) = ftv a
   ftv (TypeError err) = Set.empty

instance subMaybeType :: Substitutable (Maybe Type) where
  apply s t = apply s <$> t
  ftv (Just t) = ftv t
  ftv Nothing = Set.empty

instance listSub :: (Substitutable a) => Substitutable (List a) where
  apply s xs = map (apply s) xs
  ftv   = foldr (\a b -> Set.union (ftv a) b) Set.empty

instance subTypeEnv :: Substitutable TypeEnv where
  apply s (TypeEnv env) =  TypeEnv $ map (apply s) env
  ftv (TypeEnv env) = ftv $ snd $ unzip $ Map.toList env

instance subAD :: Substitutable AD where
  apply s (TList t) = TList (apply s t)
  apply s(TTuple t) = TTuple (apply s t)

  ftv (TList t) = ftv t
  ftv (TTuple t) = ftv t

instance subTupTVarScheme :: Substitutable (Tuple String Scheme) where
  apply s (Tuple a b) = Tuple a (apply s b)

  ftv (Tuple _ b) = ftv b

instance subQualTree :: (Substitutable a, Substitutable b, Substitutable c) => Substitutable (QualTree a b c) where
  apply s (Gen a b c) = Gen (apply s a) (apply s b) (apply s c)
  apply s (Let a b c) = Let (apply s a) (apply s b) (apply s c)
  apply s (Guard a c) = Guard (apply s a) (apply s c)

  ftv (Gen a b c) = ftv c
  ftv (Let a b c) = ftv c
  ftv (Guard a c) = ftv c

-- | Substitutable instance for the type tree.
instance subTypeTree :: Substitutable (Tree Atom (Binding (Maybe Type)) (Tuple Op (Maybe Type)) (Maybe Type)) where
  apply s (Atom t a) = Atom (apply s t) a
  apply s (List t es) = List (apply s t) (apply s es)
  apply s (NTuple t es) = NTuple (apply s t) (apply s es)
  apply s (Binary t op l r) = Binary (apply s t) (apply s op) (apply s l) (apply s r)
  apply s (Unary t op e) = Unary (apply s t) (apply s op) (apply s e)
  apply s (SectL t e op) = SectL (apply s t) (apply s e) (apply s op)
  apply s (SectR t op e) = SectR (apply s t) (apply s op) (apply s e)
  apply s (PrefixOp t op) = PrefixOp (apply s t) (apply s op)
  apply s (IfExpr t c l r) = IfExpr (apply s t) (apply s c) (apply s l) (apply s r)
  apply s (ArithmSeq t begin step end) = ArithmSeq (apply s t) (apply s begin) (apply s <$> step) (apply s <$> end)
  apply s (LetExpr t bs e) = LetExpr (apply s t) ((\(Tuple x y) -> Tuple (apply s x) (apply s y)) <$> bs) (apply s e)
  apply s (Lambda t bs body) = Lambda (apply s t) (apply s bs) (apply s body)
  apply s (App t e es) = App (apply s t) (apply s e) (apply s es)
  apply s (ListComp t e qs) = ListComp (apply s t) (apply s e) (apply s qs)
  ftv typeTree = ftv (extractFromTree typeTree)

-- | Substitutable instance for operator tuples used in the type tree.
instance subOpTuple :: Substitutable (Tuple Op (Maybe Type)) where
  apply s (Tuple op t) = Tuple op (apply s t)
  ftv (Tuple op t) = ftv t

instance subTypedBinding :: Substitutable a => Substitutable (Binding a) where
  apply s (Lit t atom) = Lit (apply s t) atom
  apply s (ConsLit t b1 b2) = ConsLit (apply s t) (apply s b1) (apply s b2)
  apply s (ListLit t lb) = ListLit (apply s t) (apply s lb)
  apply s (NTupleLit t lb) = NTupleLit (apply s t) (apply s lb)

  ftv = extractFromBinding >>> ftv

-- | A `TypeExtractable` represents a data structure holding a type which can be extracted.
class TypeExtractable a where
  extractType :: a -> Type

-- | Convenience functions for extracting types out of typed trees, typed bindings and typed quals.
-- | Note, that these functions will crash if a `Nothing` is encountered instead of a type.

instance typeExtractableTypeTree :: TypeExtractable (Tree a b o (Maybe Type)) where
  extractType tree = case extractFromTree tree of
    Just t -> t
    Nothing -> unsafeCrashWith $
      "You found a bug: the given tree should be typed (type field contains `Nothing`)."

instance typeExtractableTypeBinding :: TypeExtractable (Binding (Maybe Type)) where
  extractType binding = case extractFromBinding binding of
    Just t -> t
    Nothing -> unsafeCrashWith $
      "You found a bug: the given binding should be typed (type field contains `Nothing`)."

instance typeExtractableTypeQual :: TypeExtractable (QualTree b t (Maybe Type)) where
  extractType qual = case extractFromQualTree qual of
    Just t -> t
    Nothing -> unsafeCrashWith $
      "You found a bug: the given qual should be typed (type field contains `Nothing`)."

initUnique :: Unique
initUnique = Unique { count : 0 }

extend :: TypeEnv -> Tuple TVar Scheme -> TypeEnv
extend (TypeEnv env) (Tuple x s) = TypeEnv $ Map.insert x s env

extendMultiple :: TypeEnv -> List (Tuple TVar Scheme) -> TypeEnv
extendMultiple = foldr (flip extend)

nullSubst :: Subst
nullSubst = Map.empty

freshTVar :: Infer TVar
freshTVar = do
    Unique s <- get
    put (Unique { count: (s.count + 1) })
    pure $ "t_" <> show s.count

fresh :: Infer Type
fresh = TypVar <$> freshTVar

unify :: Type -> Type -> Infer Subst
unify UnknownType t = pure nullSubst
unify t UnknownType = pure nullSubst
unify (TypArr l r) (TypArr l' r')  = do
    s1 <- unify l l'
    s2 <- unify (apply s1 r) (apply s1 r')
    pure (s2 `compose` s1)

unify (TypVar a) t = bindVar a t
unify t (TypVar a) = bindVar a t
unify (TypCon a) (TypCon b) | a == b = pure nullSubst
unify (AD a) (AD b) | a == b = pure nullSubst
unify (AD a) (AD b) = unifyAD a b
unify t1 t2 = throwError $ normalizeTypeError $ UnificationFail t1 t2

unifyAD :: AD -> AD -> Infer Subst
unifyAD (TList a) (TList b) = unify a b
unifyAD (TTuple (Cons a as)) (TTuple (Cons b bs)) = do
  s1 <- unifyAD (TTuple as) (TTuple bs)
  s2 <- unify a b
  pure (s1 `compose` s2)
unifyAD (TTuple Nil) (TTuple Nil) = pure nullSubst

unifyAD a b = throwError $ normalizeTypeError $ UnificationFail (AD a) (AD b)

bindVar ::  TVar -> Type -> Infer Subst
bindVar a t
  | t == (TypVar a) = pure nullSubst
  | occursCheck a t = throwError $ normalizeTypeError $ InfiniteType a t
  | otherwise       = pure $ Map.singleton a t

occursCheck :: forall a.  (Substitutable a) => TVar -> a -> Boolean
occursCheck a t = a `Set.member` ftv t

compose :: Subst -> Subst -> Subst
compose s1 s2 = map (apply s1) s2 `Map.union` s1

envUnion :: TypeEnv -> TypeEnv -> TypeEnv
envUnion (TypeEnv a) (TypeEnv b) = TypeEnv $ a `Map.union` b

instantiate :: Scheme -> Infer Type
instantiate (Forall as t) = do
  as' <- traverse (const fresh) as
  let s = Map.fromFoldable $ zip as as'
  pure $ apply s t

generalize :: TypeEnv -> Type -> Scheme
generalize env t  = Forall as t
  where as = Set.toUnfoldable $ ftv t `Set.difference` ftv env

runInfer :: Infer (Tuple Subst Type) -> Either TypeError Scheme
runInfer m = case evalState (runExceptT m) initUnique of
  Left err -> Left err
  Right res -> Right $ closeOverType res

closeOverType :: (Tuple Subst Type) -> Scheme
closeOverType (Tuple sub ty) = generalize emptyTypeEnv (apply sub ty)

overlappingBindings :: List TypedBinding -> List String
overlappingBindings Nil = Nil
overlappingBindings (Cons x Nil) = Nil
overlappingBindings (Cons x xs) = (filter (\y -> elem y (concatMap boundNames xs)) (boundNames x)) <> overlappingBindings xs
  where
    boundNames :: TypedBinding -> (List String)
    boundNames = go
      where
      go (Lit _ (Name name)) = singleton name
      go (ConsLit _ b1 b2)   = go b1 <> go b2
      go (ListLit _ bs)      = foldMap go bs
      go (NTupleLit _ bs)    = foldMap go bs
      go _                 = Nil

lookupEnv :: TypeEnv -> TVar -> Infer (Tuple Subst Type)
lookupEnv (TypeEnv env) tvar = do
  case Map.lookup tvar env of
    Nothing -> throwError $ UnboundVariable tvar
    Just s  -> do t <- instantiate s
                  pure (Tuple nullSubst t)

inferType :: TypeEnv -> TypeTree -> Infer (Tuple Subst Type)
inferType env exp = do
  Tuple s t <- infer env exp
  pure $ Tuple s (extractType t)

extractBindingType :: TypedBinding -> Infer Type
extractBindingType typeBinding = case extractFromBinding typeBinding of
  Just t -> pure t
  Nothing -> throwError $ UnknownError "You found a bug, the given binding should be typed."

data InferResult a = InferResult {subst :: Subst, envi :: TypeEnv, result :: a}

inferBinding :: TypeEnv -> TypedBinding -> TypeTree -> Infer (InferResult (Tuple TypedBinding TypeTree))
inferBinding env bin e1 = do
  Tuple s1 tt <- infer env e1
  Tuple list typ <- extractBinding bin
  bindingType <- extractBindingType typ
  let extractedType = extractType tt
  s2 <- unify bindingType extractedType
  let env' = apply (s1 `compose` s2) env
      t'   = generalize env' (apply (s1 `compose` s2) extractedType)
      env'' = apply s2 (foldr (\a b -> extend b a) env' list)
  pure $ InferResult {subst: s2, envi: env'', result: (Tuple typ tt)}

inferBindings :: TypeEnv -> List (Tuple TypedBinding TypeTree) -> Infer (InferResult (List (Tuple TypedBinding TypeTree)))
inferBindings _ Nil = throwError $ UnknownError "congrats you found a bug TypeChecker.inferBindings"
inferBindings env (Cons (Tuple bin expr) Nil) = do
  InferResult {subst: s, envi: e, result: r} <- inferBinding env bin expr
  pure $ InferResult {subst: s, envi: e, result: (pure r)}
inferBindings env (Cons (Tuple bin expr) rest) = do
  InferResult {subst: s, envi: e, result: res}    <- inferBinding env bin expr
  InferResult {subst: sr, envi: er, result: resr} <- inferBindings e rest
  let sRes = s `compose` sr
  pure $ InferResult {subst: sRes, envi: er, result: (Cons res resr)}

-- | From a given lambda type tree return a tuple containing the bindings and the body type tree.
-- | This function has to be called with a lambda tree.
getLambdaBindingsAndBody :: TypeTree -> Tuple (List TypedBinding) TypeTree
getLambdaBindingsAndBody (Lambda t bindings body) = Tuple bindings body
getLambdaBindingsAndBody _ = unsafeCrashWith "Bad argument: expected lambda type tree."

-- | From a given app type tree return a tuple containing the first argument and the rest of the
-- | arguments. This function has to be called with an app tree or it will crash.
getAppArguments :: TypeTree -> Tuple TypeTree (List TypeTree)
getAppArguments (App t firstArg rest) = Tuple firstArg rest
getAppArguments _ = unsafeCrashWith "Bad argument: expected app type tree."

-- | Return the child trees of a given list type tree. The given type tree has to be a list tree.
-- | Otherwise report an error.
getListTreeChildren :: TypeTree -> List TypeTree
getListTreeChildren (List t children) = children
getListTreeChildren _ = unsafeCrashWith "Bad argument: expected list type tree."

-- | Return the child trees of a given tuple type tree. The given type tree has to be a tuple tree.
-- | Otherwise report an error.
getTupleTreeChildren :: TypeTree -> List TypeTree
getTupleTreeChildren (NTuple t children) = children
getTupleTreeChildren _ = unsafeCrashWith "Bad argument: expected tuple type tree."

-- | Perform type inference on an untyped type tree given a type environment. If a type error
-- | occurs during the inference, catch the error and put it into the top level tree node.
inferAndCatchErrors :: TypeEnv -> TypeTree -> Infer (Tuple Subst TypeTree)
inferAndCatchErrors env expr = catchError
  (infer env expr)
  (\typeError -> pure $ Tuple nullSubst (insertIntoTree (Just $ TypeError typeError) expr))

-- | Given a type environment as well as an untyped expression tree, infer the type of the given
-- | tree and return a typed tree as well as the map of substitutions.
infer :: TypeEnv -> TypeTree -> Infer (Tuple Subst TypeTree)
infer env ex = case ex of
  Atom _ atom@(Name name) -> case name of
    "mod" -> pure $ Tuple nullSubst (Atom (Just $ TypCon "Int" `TypArr` (TypCon "Int" `TypArr` TypCon "Int")) atom)
    "div" -> pure $ Tuple nullSubst (Atom (Just $ TypCon "Int" `TypArr` (TypCon "Int" `TypArr` TypCon "Int")) atom)
    _     -> do
      Tuple s t <- lookupEnv env name
      pure (Tuple s $ Atom (Just t) atom)
  Atom _ atom@(Bool _) -> pure (Tuple nullSubst $ Atom (Just $ TypCon "Bool") atom)
  Atom _ atom@(Char _) -> pure (Tuple nullSubst $ Atom (Just $ TypCon "Char") atom)
  Atom _ atom@(AInt _) -> pure (Tuple nullSubst $ Atom (Just $ TypCon "Int") atom)

  Lambda _ (bin : Nil) e -> do
    Tuple envL typedBinding <- extractBinding bin
    let env' = env `extendMultiple` envL
    Tuple subst tree <- infer env' e
    pure $ Tuple subst $ apply subst (Lambda (Just $ (extractType typedBinding) `TypArr` (extractType tree)) (typedBinding : Nil) tree)

  Lambda _ (bin : bins) e -> do
    Tuple envL typedBinding <- extractBinding bin
    let env' = env `extendMultiple` envL
    Tuple subst lambda <- infer env' (Lambda Nothing bins e)
    Tuple bindings body <- pure $ getLambdaBindingsAndBody lambda
    let lambdaType = extractType lambda
    let inferredType = (extractType typedBinding) `TypArr` lambdaType
    pure $ Tuple subst (apply subst $ Lambda (Just inferredType) (typedBinding : bindings) body)

  Lambda _ Nil e -> infer env e

  App _ e1 (e2 : Nil) -> do
    tv <- fresh
    Tuple s1 tt1 <- infer env e1
    Tuple s2 tt2 <- infer (apply s1 env) e2
    s3       <- unify (apply (s1  `compose` s2) (extractType tt1)) (TypArr (extractType tt2) tv)
    pure (Tuple (s3 `compose` s2 `compose` s1) (apply s3 (App (Just tv) tt1 (Cons tt2 Nil))))

  App _ e1 (e2 : es) -> do
    Tuple subst appTree <- infer env (App Nothing (App Nothing e1 (e2 : Nil)) es)
    Tuple firstArg rest <- pure $ getAppArguments appTree
    Tuple firstArgOfFirstArg restOfFirstArg <- pure $ getAppArguments firstArg
    pure $ Tuple subst (App (extractFromTree appTree) firstArgOfFirstArg (restOfFirstArg <> rest))

  ListComp _ expr quals -> do
    Tuple sq (Tuple tq env') <- inferQuals env quals
    Tuple s tt <- infer env' expr
    let s' = sq `compose` s
    pure $ Tuple s' $ apply s' $ ListComp (Just $ AD $ TList $ extractType tt) tt tq

  LetExpr _ bindings expr -> case overlappingBindings (fst <$> bindings) of
    Cons x _ -> throwError $ UnknownError $ "Conflicting definitions for \'" <> x <> "\'"
    Nil      -> do
      InferResult {subst: sb, envi: envb, result: resb} <- inferBindings env bindings
      Tuple se te <- infer envb expr
      let s = sb `compose` se
      pure $ Tuple s $ apply s $ LetExpr (extractFromTree te) resb te

  IfExpr _ cond e1 e2 -> do
    tvar <- freshTVar
    let t = TypVar tvar
    let ifType = TypArr (TypCon "Bool") (TypArr t (TypArr t  t))
    let env' = env `extend` (Tuple "if" (Forall (tvar : Nil) ifType))
    Tuple subst tree <- infer env' (App Nothing (Atom Nothing (Name "if")) (cond : e1 : e2 : Nil))
    Tuple firstArg rest <- pure $ getAppArguments tree
    let typedCond = unsafePartial $ fromJust $ rest !! 0
    let typedE1 = unsafePartial $ fromJust $ rest !! 1
    let typedE2 = unsafePartial $ fromJust $ rest !! 2
    pure $ Tuple subst (apply subst $ IfExpr (extractFromTree tree) typedCond typedE1 typedE2)

  ArithmSeq _ begin jstep jend -> do
    Tuple s1 t1 <- infer env begin
    tup2 <- traverse (infer env) jstep
    tup3 <- traverse (infer env) jend
    let t2 = snd <$> tup2
    let t3 = snd <$> tup3
    let s2 = maybe nullSubst fst tup2
    let s3 = maybe nullSubst fst tup3
    let s  = s1 `compose` s2 `compose` s3
    let tt = extractType t1
    let stepTree = extractType <$> t2
    let endTree = extractType <$> t3
    let typeMissMatch m1 m2 = fromMaybe (UnknownError "congrats you found a bug TypeChecker.infer (ArithmSeq begin jstep jend)") (normalizeTypeError <$> lift2 UnificationFail m1 m2)
    ifM (pure (fromMaybe false (lift2 (/=) (Just tt) stepTree)))
      (throwError (typeMissMatch (Just tt) stepTree))
      (ifM (pure (fromMaybe false (lift2 (/=) (Just tt) endTree)))
        (throwError (typeMissMatch (Just tt) endTree))
        (ifM (pure (fromMaybe false (lift2 (/=) stepTree endTree)))
          (throwError (typeMissMatch stepTree endTree))
          (case tt of
            TypCon "Int"  -> pure $ Tuple s $ apply s $ ArithmSeq (Just $ AD (TList tt)) t1 t2 t3
            TypCon "Bool" -> pure $ Tuple s $ apply s $ ArithmSeq (Just $ AD (TList tt)) t1 t2 t3
            TypCon "Char" -> pure $ Tuple s $ apply s $ ArithmSeq (Just $ AD (TList tt)) t1 t2 t3
            _             -> throwError $ NoInstanceOfEnum tt)))

  PrefixOp _ (Tuple op _) -> do
    Tuple s t <- inferOp env op
    pure (Tuple s $ PrefixOp (Just t) (Tuple op (Just t)))

  SectL _ e (Tuple op _) -> do
    tv <- fresh
    Tuple s1 t1 <- inferOp env op
    Tuple s2 t2 <- infer (apply s1 env) e
    s3       <- unify (apply s2 t1) (TypArr (extractType t2) tv)
    pure (Tuple (s3 `compose` s2 `compose` s1) (apply s3 (SectL (Just tv) t2 (Tuple op (Just t1)))))

  SectR _ (Tuple op _) e -> do
    Tuple s1 opType <- inferOp env op
    Tuple a arr <- pure $ getArrowTypes opType
    Tuple b c <- pure $ getArrowTypes arr
    Tuple s2 tree <- infer env e
    s3 <- unify (apply s1 b) (extractType tree)
    let s4 = (s3 `compose` s1 `compose` s1)
    pure $ Tuple s4 (apply s4 (SectR (Just $ TypArr a c) (Tuple op (Just opType)) tree))

  Unary _ (Tuple op _) e -> do
    tv <- fresh
    Tuple s1 opType <- inferOp env op
    Tuple s2 t2 <- infer (apply s1 env) e
    s3 <- unify (apply s2 opType) (TypArr (extractType t2) tv)
    pure (Tuple (s3 `compose` s2 `compose` s1) (apply s3 (Unary (Just tv) (Tuple op (Just opType)) t2)))

  Binary _ (Tuple op mtype) e1 e2 -> do
    Tuple subst tree <- infer env (App Nothing (PrefixOp Nothing (Tuple op mtype)) (e1 : e2 : Nil))
    Tuple firstTree rest <- pure $ getAppArguments tree
    let tt1 = unsafePartial $ fromJust $ (rest !! 0)
    let tt2 = unsafePartial $ fromJust $ (rest !! 1)
    pure $ Tuple subst (Binary (extractFromTree tree) (Tuple op (extractFromTree firstTree)) tt1 tt2)

  List _ (e : es) -> do
    Tuple s1 listTree <- infer env (List Nothing es)
    Tuple s2 tree2 <- infer (apply s1 env) e
    let listChildren = getListTreeChildren listTree
    let listElement = getListElementType $ extractType listTree
    let otherElementType = extractType tree2
    s3 <- unify (apply s2 listElement) otherElementType
    let updatedListTree = List (Just $ AD $ TList otherElementType) (tree2 : listChildren)
    pure $ Tuple (s3 `compose` s2 `compose` s1) (apply s3 updatedListTree)

  List _ Nil -> do
    tv <- fresh
    pure (Tuple nullSubst $ List (Just $ AD $ TList tv) Nil)

  NTuple _ (e : Nil) -> do
    Tuple s t <- infer env e
    pure $ Tuple s $ NTuple (Just $ AD $ TTuple $ (extractType t) : Nil) (t : Nil)

  NTuple _ (e : es) -> do
    -- Given a tuple (a, b, c, ...) infer the type of (b, c, ...) and get the typed tree of
    -- (b, c, ...). Also extractFromTree the type of (b, c, ...) as well as the types of the individual
    -- elements.
    Tuple s1 tupleTree <- infer env (NTuple Nothing es)
    let inferredType = extractType tupleTree
    let types = getTupleElementTypes inferredType
    let tupleChildren = getTupleTreeChildren tupleTree

    -- Infer the type of the first tuple element and add it to the already typed rest of the tuple.
    Tuple s2 first <- infer (apply s1 env) e
    let updeatedTupleTree = NTuple (Just $ AD $ TTuple $ (extractType first) : types) (first : tupleChildren)
    pure $ Tuple (s2 `compose` s2) updeatedTupleTree

  tree -> unsafeCrashWith $ "Bad argument: `infer` didn't expect the input " <> show tree <> "."

inferQual :: TypeEnv -> TypeQual -> Infer (Tuple Subst (Tuple TypeQual TypeEnv))
inferQual env (Let _ bin e1) = do
  Tuple s1 tt <- infer env e1
  Tuple mappings typedBinding <- extractBinding bin
  bindingType <- extractBindingType typedBinding
  let extractedType = extractType tt
  s2 <- unify bindingType extractedType
  let env' = apply s2 $ env `extendMultiple` mappings
  let subst = s1 `compose` s2
  pure $ Tuple subst $ Tuple (apply subst (Let (Just extractedType) typedBinding tt)) env'

inferQual env (Gen _ bin expr) = do
  Tuple s1 tt <- infer env expr
  -- Think: [ bin | x <- expr], where x is found in bin
  let extractedType = extractType tt
  case extractedType of
    -- Type is: [T]
    AD (TList t) -> do
      (Tuple binding typedBinding) <- extractBinding bin
      s2 <- unify (extractType typedBinding) t
      let env' = apply s2 $ env `extendMultiple` binding
      let subst = s1 `compose` s2
      pure $ Tuple subst $ Tuple (apply subst (Gen (Just t) typedBinding tt)) env'

    -- Type is: T (a hopefully bound type variable)
    TypVar tvar -> do
      -- First extractFromTree the binding and the corresponding type t0.
      -- Then unify [t0] with the type variable tvar ([t0] ~ tvar).
      -- Apply the resulting substitution to the environment extended by the binding.
      Tuple binding typedBinding <- extractBinding bin
      s2 <- unify (AD $ TList $ extractType typedBinding) (TypVar tvar)
      let env' = apply s2 $ env `extendMultiple` binding
      let typeTree = Gen (Just $ TypVar tvar) typedBinding tt
      let subst = s1 `compose` s2
      pure $ Tuple subst $ Tuple (apply subst typeTree) env'

    _ -> do
      tv <- fresh
      throwError $ normalizeTypeError $ UnificationFail extractedType (AD (TList tv))

inferQual env (Guard _ expr) = do
  Tuple s tt <- infer env expr
  let extractedType = extractType tt
  case extractedType of
    TypCon "Bool" -> pure $ Tuple s $ Tuple (apply s (Guard (Just extractedType) tt)) env
    _             -> throwError $ normalizeTypeError $ UnificationFail extractedType (TypCon "Bool")

inferQuals :: TypeEnv -> List TypeQual -> Infer (Tuple Subst (Tuple (List TypeQual) TypeEnv))
inferQuals env Nil = pure $ Tuple nullSubst $ Tuple Nil emptyTypeEnv
inferQuals env (Cons x rest) = do
  Tuple s  (Tuple t  env1) <- inferQual env x
  Tuple sr (Tuple tr env2) <- inferQuals (apply s env1) rest
  let s' = s `compose` sr
  pure $ Tuple s' $ Tuple (t `Cons` tr) (envUnion env2 env1)

inferOp :: TypeEnv -> Op -> Infer (Tuple Subst Type)
inferOp env op = do
  a <- fresh
  b <- fresh
  c <- fresh
  case op of
    Composition ->
      f ((b `TypArr` c) `TypArr` ((a `TypArr` b) `TypArr` (a `TypArr` c)))
    Power -> int3
    Mul ->  int3
    Add -> int3
    Sub -> int3
    Colon -> f (a `TypArr` ((AD $ TList a) `TypArr` (AD $ TList a)))
    Append -> f ((AD $ TList a) `TypArr` ((AD $ TList a) `TypArr` (AD $ TList a)))
    Equ -> aBool a
    Neq -> aBool a
    Lt -> aBool a
    Leq -> aBool a
    Gt -> aBool a
    Geq -> aBool a
    And -> f (TypCon "Bool" `TypArr` (TypCon "Bool" `TypArr` TypCon "Bool"))
    Or -> f (TypCon "Bool" `TypArr` (TypCon "Bool" `TypArr` TypCon "Bool"))
    Dollar -> f ((a `TypArr` b) `TypArr` (a `TypArr` b))
    InfixFunc name -> inferType env (Atom Nothing (Name name))
 where
  f typ = pure (Tuple nullSubst typ)
  int3 = f (TypCon "Int" `TypArr` (TypCon "Int" `TypArr` TypCon "Int"))
  aBool a = f (a `TypArr` (a `TypArr` TypCon "Bool"))

inferDef :: TypeEnv -> Definition -> Infer (Tuple Subst Type)
inferDef env (Def str bin exp) = do
    tv <- fresh
    let env' = env `extend` (Tuple str (Forall Nil tv))
    let exp' = Lambda Nothing bin exp
    Tuple s1 tt <- infer env' exp'
    let extractedType1 = extractType tt
    let env'' = env `extend` (Tuple str (Forall Nil (apply s1 extractedType1)))
    Tuple s2 tt2 <- infer env'' exp'
    let extractedType2 = extractType tt2
    s3 <- unify (apply s1 extractedType1) (apply s2 extractedType2)
    pure $ Tuple (s3 `compose` s1) (apply s3 (apply s1 extractedType1))

-- | Determine if the given binding represents a lit pattern.
isLit :: forall a. Binding a -> Boolean
isLit (Lit _ _) = true
isLit _ = false

-- | Determine if the given binding represents a cons pattern.
isConsLit :: forall a. Binding a -> Boolean
isConsLit (ConsLit _ _ _) = true
isConsLit _ = false

-- | Determine if the given binding represents a list pattern.
isListLit :: forall a. Binding a -> Boolean
isListLit (ListLit _ _) = true
isListLit _ = false

-- | Determine if the given binding represents a tuple pattern.
isTupleLit :: forall a. Binding a -> Boolean
isTupleLit (NTupleLit _ _) = true
isTupleLit _ = false

-- | Return the name of the given binding (a lit pattern of the type).
getLitName :: forall a. Binding a -> String
getLitName (Lit _ (Name name)) = name
getLitName _ = ""

-- | Given a list type return the type of the list elements.
getListElementType :: Type -> Type
-- Element type of [?] is ?.
getListElementType UnknownType = UnknownType
-- Element type of [T] is T.
getListElementType (AD (TList t)) = t
getListElementType _ = unsafeCrashWith "Bad argument: expected list type."

-- | Given a tuple type return the types of the tuple elements.
getTupleElementTypes :: Type -> List Type
getTupleElementTypes (AD (TTuple ts)) = ts
getTupleElementTypes _ = unsafeCrashWith "Bad argument: expected list type."

getArrowTypes :: Type -> Tuple Type Type
getArrowTypes (TypArr t1 t2) = Tuple t1 t2
getArrowTypes _ = unsafeCrashWith "Bad argument: expected arrow type."

-- | Given a list pattern return the binding list.
getListLitBindings :: forall a. Binding a -> List (Binding a)
getListLitBindings (ListLit _ bindings) = bindings
getListLitBindings _ = Nil

-- TODO: Write test.
-- | Given a list of untyped bindings infer the types into a list of mappings and typed bindings.
extractListLit :: List TypedBinding -> Infer (List (Tuple TVarMappings TypedBinding))
extractListLit bs = traverse extractBinding bs

-- | Given a binding (which is not yet typed) infer the type of the binding and accumulate the
-- | generated type variables into a map.
extractBinding :: TypedBinding -> Infer (Tuple TVarMappings TypedBinding)
extractBinding (Lit _ (Name name)) = do
  tv <- fresh
  pure $ Tuple (Tuple name (Forall Nil tv) : Nil) $ Lit (Just tv) (Name name)
extractBinding (Lit _ (Bool x)) = pure $ Tuple Nil $ Lit (Just $ TypCon "Bool") (Bool x)
extractBinding (Lit _ (Char x)) = pure $ Tuple Nil $ Lit (Just $ TypCon "Char") (Char x)
extractBinding (Lit _ (AInt x)) = pure $ Tuple Nil $ Lit (Just $ TypCon "Int") (AInt x)

-- We function expects a cons pattern (e.g. `(x:xs)`) and infers the type of the sub-patterns.
-- Conceptual example: Calling the function (x:xs) results in x :: a, xs :: [a] (where a is a newly
-- chosen type variable). The resulting mapping holds x :: a and xs :: [a], while the updated
-- binding holds the additional type informations (x :: a : xs :: [a]).
extractBinding (ConsLit _ fst snd) = do
  t <- fresh
  Tuple mapping1 typedBinding1 <- extractBinding fst
  let type1 = extractType typedBinding1
  subst1 <- unify t type1
  if isLit snd
    then do
      -- The second pattern is a literal pattern, therefore it has the type [t].
      let listType = AD $ TList (apply subst1 t)
      let name = getLitName snd
      -- Update the mapping and the binding.
      let mapping = (Tuple name $ Forall Nil listType) : apply subst1 mapping1
      let updatedBinding = apply subst1 $
        ConsLit (Just listType) typedBinding1 (Lit (Just listType) (Name name))
      pure $ Tuple mapping updatedBinding
    else do
      -- The second pattern is a list, cons or tuple pattern of type t2. [t3] ~ t2 => t3 ~ t.
      Tuple mapping2 typedBinding2 <- extractBinding snd
      let type2 = getListElementType $ extractType typedBinding2
      subst2 <- unify (apply subst1 t) type2
      -- Update the mapping and the binding.
      let mapping = apply subst2 $ apply subst1 $ mapping1 <> mapping2
      let updatedBinding = apply subst2 $ apply subst1 $
        ConsLit (Just $ AD $ TList type2) typedBinding1 typedBinding2
      pure $ Tuple mapping updatedBinding

extractBinding (ListLit _ bindings) = do
  tv <- fresh
  let ini = Tuple Nil (ListLit (Just tv) Nil) :: Tuple TVarMappings TypedBinding
  bs <- extractListLit bindings
  Tuple mapping typedBinding <- foldM f ini bs
  let updatedListLit = ListLit (Just $ AD $ TList $ extractType typedBinding) (getListLitBindings typedBinding)
  pure $ Tuple mapping updatedListLit
  where
    f :: Tuple TVarMappings TypedBinding -> Tuple TVarMappings TypedBinding ->
         Infer (Tuple TVarMappings TypedBinding)
    f (Tuple mapping1 listLit1) (Tuple mapping2 listLit2) = do
      let bindingType = extractType listLit2
      let typedBindings = getListLitBindings listLit1
      let listLitType = extractType listLit1
      subst <- unify listLitType bindingType
      pure $ Tuple
        (apply subst (mapping1 <> mapping2))
        (apply subst (ListLit (Just listLitType) (listLit2 : typedBindings)))

extractBinding (NTupleLit _ bindings) = do
  bs <- extractListLit bindings
  let tup = unzip bs
  let tupleTypes = map extractType (snd tup)
  pure $ Tuple (concat $ fst tup) (NTupleLit (Just $ AD $ TTuple $ tupleTypes) (snd tup))

getTypEnv :: TypedBinding -> TypeEnv -> Maybe TypeEnv
getTypEnv b env = case evalState (runExceptT (extractBinding b)) initUnique of
    Left _ -> Nothing
    Right (Tuple bs _) -> Just $ env `extendMultiple` bs

getTypEnvFromList :: List TypedBinding -> TypeEnv -> Maybe TypeEnv
getTypEnvFromList bs env = do
                  mTypList <- traverse (flip getTypEnv emptyTypeEnv) bs
                  pure $ foldr (\a b -> unionTypeEnv a b) env mTypList

unionTypeEnv :: TypeEnv -> TypeEnv -> TypeEnv
unionTypeEnv (TypeEnv a) (TypeEnv b) = TypeEnv (Map.union a b)

inferGroup :: TypeEnv -> List Definition -> Infer (Tuple Subst Type)
inferGroup _ Nil = throwError $ UnknownError "Cant type empty Group"
inferGroup env (Cons def1 Nil) = inferDef env def1
inferGroup env (Cons def1 defs) = do
  Tuple s1 t1 <- inferDef env def1
  Tuple s2 t2 <- inferGroup env defs
  s3 <- unify t1 t2
  pure $ Tuple s3 (apply s3 t1)

buildTypeEnv :: List Definition -> Either TypeError TypeEnv
buildTypeEnv Nil = Right emptyTypeEnv
buildTypeEnv defs = buildTypeEnvFromGroups emptyTypeEnv groupMap keys
  where
    groupMap = buildGroups defs
    keys = Map.keys groupMap

buildGroups :: List Definition -> Map.Map String (List Definition)
buildGroups Nil = Map.empty
buildGroups (Cons def@(Def str bin exp) Nil) =
  Map.singleton str (Cons def Nil)

buildGroups (Cons def@(Def str bin exp) defs) =
  case binList of
    Just list -> Map.insert str (Cons def list) defMap
    Nothing -> Map.insert str (Cons def Nil) defMap
  where
    defMap = buildGroups defs
    binList = Map.lookup str defMap

buildTypeEnvFromGroups :: TypeEnv -> Map.Map String (List Definition)
  -> List String -> Either TypeError TypeEnv
buildTypeEnvFromGroups env _ Nil = Right env
buildTypeEnvFromGroups env groupMap k@(Cons key keys) =
  case mayDefs of
    Nothing -> Left $ UnboundVariable key
    Just defs -> case runInfer $ inferGroup env defs of
      Right scheme -> buildTypeEnvFromGroups
        (env `extend` (Tuple key scheme)) (Map.delete key groupMap) keys
      Left (UnboundVariable var) -> buildTypeEnvFromGroups
        env groupMap (Cons var (delete var k))
      Left err -> Left err
  where
    mayDefs = Map.lookup key groupMap

typeProgramn :: List Definition -> TypeTree -> Either TypeError Scheme
typeProgramn defs tt = case runInfer <$>
    (inferType <$> (buildTypeEnv defs) <*> pure tt) of
  Left err -> Left err
  Right a -> a

typeTreeProgram :: List Definition -> TypeTree -> Either TypeError TypeTree
typeTreeProgram defs tt = case m of
  Left e -> Left e
  Right m' -> case evalState (runExceptT m') initUnique of
    Left err -> Left err
    Right res -> Right $ closeOverTypeTree res
  where
    m = (inferAndCatchErrors <$> (buildTypeEnv defs) <*> pure tt)

-- | Given a type environment as well as a type tree call infer and return the (partially) typed
-- | tree. The resulting tree is not completely typed whenever a type error occurred. In this case
-- | the type error will appear as type of the top level tree node, while all other nodes remain
-- | untyped.
typeTreeProgramEnv :: TypeEnv -> TypeTree -> Either TypeError TypeTree
typeTreeProgramEnv env tt = case evalState (runExceptT (inferAndCatchErrors env tt)) initUnique of
      Left err -> Left err
      Right result@(Tuple subst tree) -> Right (closeOverTypeTree result)

closeOverTypeTree :: (Tuple Subst TypeTree) -> TypeTree
closeOverTypeTree (Tuple s tt) = normalizeTypeTree (apply s tt)

emptyType :: Type
emptyType = TypCon ""

-- typeTreeProgramEnv env expr
-- types subtree if typ correct
buildPartiallyTypedTree :: TypeEnv -> TypeTree -> TypeTree
buildPartiallyTypedTree env e = case typeTreeProgramEnv env e of
  Right tt -> tt
  Left err -> f err e
  where
  f :: TypeError -> TypeTree -> TypeTree
  f err (Atom _ atom) = Atom (Just $ TypeError err) atom
  f err (List _ ls) = List (Just $ TypeError err) (map (buildPartiallyTypedTree env) ls)
  f err (NTuple _ ls) = NTuple (Just $ TypeError err) (map (buildPartiallyTypedTree env) ls)
  f err (Binary _ op e1 e2) = Binary (Just $ TypeError err) (typeOp op) (buildPartiallyTypedTree env e1) (buildPartiallyTypedTree env e2)
  f err (SectL _ e op) = SectL (Just $ TypeError err) (buildPartiallyTypedTree env e) (typeOp op)
  f err (SectR _ op e) = SectR (Just $ TypeError err) (typeOp op) (buildPartiallyTypedTree env e)
  f err (PrefixOp _ _) = PrefixOp (Just $ TypeError err) (Tuple Add (Just $ TypeError err))
  f err (IfExpr _ e1 e2 e3) = IfExpr (Just $ TypeError err) (buildPartiallyTypedTree env e1) (buildPartiallyTypedTree env e2) (buildPartiallyTypedTree env e3)
  f err (ArithmSeq _ e1 e2 e3) = ArithmSeq (Just $ TypeError err) (buildPartiallyTypedTree env e1) ((buildPartiallyTypedTree env) <$> e2) ((buildPartiallyTypedTree env) <$> e3)
  f err (LetExpr _ bin expr) = let
    tup   = buildPartiallyTypedTreeBindings env bin
    env'  = fst tup
    binds = snd tup in LetExpr (Just $ TypeError err) binds (buildPartiallyTypedTree env' expr)

  f err (Lambda _ bs e) = let f' env' = Lambda (Just $ TypeError err) (map g bs) (buildPartiallyTypedTree env' e) in
                    case getTypEnvFromList bs env of
                          Nothing -> f' env
                          Just env' -> f' env'
  f err (App _ e es) = App (Just $ TypeError err) (buildPartiallyTypedTree env e) (map (buildPartiallyTypedTree env) es)

  f err (ListComp _ e es) = ListComp (Just $ TypeError err) (buildPartiallyTypedTree env e) (map (buildPartiallyTypedTreeQual err env) es)
  f err (Unary _ op e) = Unary (Just $ TypeError err) (typeOp op) (buildPartiallyTypedTree env e)

  g :: forall m. Binding m -> TypedBinding
  g (Lit _ atom) = Lit (Just emptyType) atom
  g (ConsLit _ b1 b2) = ConsLit (Just emptyType) (g b1) (g b2)
  g (ListLit _ bs) = ListLit (Just emptyType) (map g bs)
  g (NTupleLit _ bs) = NTupleLit (Just emptyType) (map g bs)

  typeOp :: Tuple Op MType -> Tuple Op MType
  typeOp (Tuple op mtype) = case typeTreeProgramEnv env (PrefixOp Nothing (Tuple op mtype)) of
    Left err -> Tuple op (Just $ TypeError err)
    Right (PrefixOp (Just typ) _) -> Tuple op (Just typ)
    Right _ -> Tuple op (Just $ TypeError $ UnknownError "TODO: stupid error")

  buildPartiallyTypedTreeQual :: TypeError -> TypeEnv -> TypeQual -> TypeQual
  buildPartiallyTypedTreeQual err env qual = case qual of
    Let _ bin expr -> let env' = fromMaybe env (getTypEnvFromList (singleton bin) env) in
      Let (Just $ TypeError err) (g bin) (buildPartiallyTypedTree env' expr)
    Gen _ bin expr -> let env' = fromMaybe env (getTypEnvFromList (singleton bin) env) in
      Gen (Just $ TypeError err) (g bin) (buildPartiallyTypedTree env' expr)
    Guard _ expr   -> Guard (Just $ TypeError err) (buildPartiallyTypedTree env expr)

  buildPartiallyTypedTreeBindings :: TypeEnv -> List (Tuple TypedBinding TypeTree) -> Tuple TypeEnv (List (Tuple TypedBinding TypeTree))
  buildPartiallyTypedTreeBindings env binds = case binds of
    Nil                   -> Tuple env Nil
    Cons (Tuple b e) bs -> let
      t     = buildPartiallyTypedTree env e
      env'  = fromMaybe env (getTypEnv b env)
      env'' = envUnion env env' in
        case buildPartiallyTypedTreeBindings env'' bs of
          Tuple envR rest -> Tuple envR $ (Tuple (g b) t) : rest

eqScheme :: Scheme -> Scheme -> Boolean
eqScheme (Forall l1 t1) (Forall l2 t2)
  = ((length l1) == (length l2)) && (fst (eqType Map.empty t1 t2))

eqType :: Map.Map TVar TVar -> Type -> Type -> Tuple Boolean (Map.Map TVar TVar)
eqType map (TypVar a) (TypVar b) = case  Map.lookup a map of
  Just b' -> Tuple (b' == b) (map)
  Nothing -> Tuple true (Map.insert a b map)
eqType map (TypCon a) (TypCon b) = Tuple (a == b) map
eqType map (TypArr a b) (TypArr a' b') = Tuple (fst tup1 && fst tup2) (snd tup2)
  where
  tup1 = eqType map a a'
  tup2 = eqType (snd tup1) b b'
eqType map (AD (TList a)) (AD (TList b)) = eqType map a b
eqType map (AD (TTuple a)) (AD (TTuple b)) = eqTypeList map a b
eqType map _ _ = Tuple false map

eqTypeList :: Map.Map TVar TVar -> List Type -> List Type -> Tuple Boolean (Map.Map TVar TVar)
eqTypeList map (Cons a as) (Cons b bs) = let tup1 = eqType map a b in if (fst tup1)
  then eqTypeList (snd tup1) as bs
  else Tuple false (snd tup1)
eqTypeList map Nil Nil = Tuple true map
eqTypeList map _ _ = Tuple false map

normalizeType :: Type -> Type
normalizeType t = fst $ runState (helpTypeToABC t) {count: 0, env: empty}

normalizeTypeError :: TypeError -> TypeError
normalizeTypeError (UnificationFail t1 t2) = UnificationFail (normalizeType t1) (normalizeType t2)
normalizeTypeError (InfiniteType tvar t) = InfiniteType (prettyPrintType $ normalizeType $ TypVar tvar) (normalizeType t)
normalizeTypeError error = error

normalizeTypeTree :: TypeTree -> TypeTree
normalizeTypeTree tt = fst $ runState (helptxToABC tt) {count : 0, env : empty}

helptxToABC :: TypeTree -> State {count :: Int, env :: Map String String} TypeTree
helptxToABC tt = go tt
  where
    go (Atom t atom) = helpMTypeToABC t >>= \t -> pure $ Atom t atom
    go (List t tts) = do
      t' <- helpMTypeToABC t
      tts' <- traverse helptxToABC tts
      pure $ List t' tts'
    go (NTuple t tts) = do
      t' <- helpMTypeToABC t
      tts' <- traverse helptxToABC tts
      pure $ NTuple t' tts'
    go (Binary t (Tuple op opType) tt1 tt2) = do
      t' <- helpMTypeToABC t
      opType' <- helpMTypeToABC opType
      tt1' <- helptxToABC tt1
      tt2' <- helptxToABC tt2
      pure $ Binary t' (Tuple op opType') tt1' tt2'
    go (Unary t (Tuple op opType) tt) = do
      t' <- helpMTypeToABC t
      opType' <- helpMTypeToABC opType
      tt' <- helptxToABC tt
      pure $ (Unary t' (Tuple op opType') tt')
    go (SectL t tt (Tuple op opType)) = do
      t' <- helpMTypeToABC t
      opType' <- helpMTypeToABC opType
      tt' <- helptxToABC tt
      pure $ SectL t' tt' (Tuple op opType')
    go (SectR t (Tuple op opType) tt) = do
      t' <- helpMTypeToABC t
      opType' <- helpMTypeToABC opType
      tt' <- helptxToABC tt
      pure $ SectR t' (Tuple op opType') tt'
    go (PrefixOp op t) = helpMTypeToABC op >>= \op -> pure $ PrefixOp op t
    go (IfExpr t tt1 tt2 tt3) = do
      t' <- helpMTypeToABC t
      tt1' <- helptxToABC tt1
      tt2' <- helptxToABC tt2
      tt3' <- helptxToABC tt3
      pure $ IfExpr t' tt1' tt2' tt3'
    go (ArithmSeq t tt1 tt2 tt3) = do
      t'   <- helpMTypeToABC t
      tt1' <- helptxToABC tt1
      tt2' <- traverse helptxToABC tt2
      tt3' <- traverse helptxToABC tt3
      pure $ ArithmSeq t' tt1' tt2' tt3'
    go (LetExpr t bin tt) = do
      t'   <- helpMTypeToABC t
      bin' <- traverse (\(Tuple x y) -> lift2 Tuple (helpBindingToABC x) (helptxToABC y)) bin
      tt'  <- helptxToABC tt
      pure $ LetExpr t' bin' tt'
    go (Lambda t tbs tt) = do
      t' <- helpMTypeToABC t
      tbs' <- traverse helpBindingToABC tbs
      tt' <- helptxToABC tt
      pure $ Lambda t' tbs' tt'
    go (App t tt tts) = do
      t' <- helpMTypeToABC t
      tt' <- helptxToABC tt
      tts' <- traverse helptxToABC tts
      pure $ App t' tt' tts'
    go (ListComp t tt tts) = do
      t'   <- helpMTypeToABC t
      tt'  <- helptxToABC tt
      tts' <- traverse helptxToABCQual tts
      pure $ ListComp t' tt' tts'

helptxToABCQual :: TypeQual -> State {count :: Int, env :: Map String String} TypeQual
helptxToABCQual q = case q of
  Gen t b e -> do
    t' <- helpMTypeToABC t
    b' <- helpBindingToABC b
    e' <- helptxToABC e
    pure $ Gen t' b' e'
  Let t b e -> do
    t' <- helpMTypeToABC t
    b' <- helpBindingToABC b
    e' <- helptxToABC e
    pure $ Let t' b' e'
  Guard t e -> do
    t' <- helpMTypeToABC t
    e' <- helptxToABC e
    pure $ Guard t' e'

helpTypeToABC :: Type -> State {count :: Int, env :: Map String String} Type
helpTypeToABC t = go t
  where
    go (TypVar var) = do
       {env: env} :: {count :: Int, env :: Map String String} <- get
       case lookup var env of
         Just var' -> pure $ TypVar var'
         Nothing -> do
           {count: count} <- get
           let newVarName = getNthName count
           let env' = insert var newVarName env
           put {count: count + 1, env: env'}
           pure $ TypVar newVarName
    go (TypArr t1 t2) = do
         t1' <- helpTypeToABC t1
         t2' <- helpTypeToABC t2
         pure $ TypArr t1' t2'
    go (AD a) = helpADTypeToABC a >>= \a -> pure $ AD a
    go a = pure a

helpMTypeToABC :: Maybe Type -> State {count :: Int, env :: Map String String} (Maybe Type)
helpMTypeToABC mt = case mt of
    Nothing -> pure Nothing
    Just t -> helpTypeToABC t >>= pure <<< Just

helpADTypeToABC :: AD -> State {count :: Int, env :: (Map String String)} AD
helpADTypeToABC (TList t) = helpTypeToABC t >>= \t -> pure $ TList t
helpADTypeToABC (TTuple ts) = traverse helpTypeToABC ts >>= \ts -> pure $ TTuple ts

helpBindingToABC :: TypedBinding -> State {count :: Int, env :: Map String String} TypedBinding
helpBindingToABC bin = go bin
  where
    go (Lit t atom) = do
      t' <- helpMTypeToABC t
      pure $ Lit t' atom
    go (ConsLit t b1 b2) = do
      b1' <- helpBindingToABC b1
      b2' <- helpBindingToABC b2
      t' <- helpMTypeToABC t
      pure $ ConsLit t' b1' b2'
    go (ListLit t tbs) = do
      tbs' <- traverse helpBindingToABC tbs
      t' <- helpMTypeToABC t
      pure $ ListLit t' tbs'
    go (NTupleLit t tbs) = do
      tbs' <- traverse helpBindingToABC tbs
      t' <- helpMTypeToABC t
      pure $ NTupleLit t' tbs'

-- Given an int generate an array of integers used as indices into the alphabet in `getNthName`.
-- Example: map indexList (700..703) => [[24,25],[25,25],[0,0,0],[1,0,0]]
indexList :: Int -> Array Int
indexList n | n `div` 26 > 0 = n `mod` 26 `Array.cons` indexList (n `div` 26 - 1)
indexList n = [n `mod` 26]

-- Given an int choose a new name. We choose names simply by indexing into the alphabet. As soon
-- "z" is reached, begin with "aa" and so on.
-- Example: map getNthName (700..703) => ["zy","zz","aaa","aab"]
getNthName :: Int -> String
getNthName = fromCharArray <<< toCharArray <<< Array.reverse <<< indexList
  where toCharArray = map (Char.fromCharCode <<< ((+) 97))
