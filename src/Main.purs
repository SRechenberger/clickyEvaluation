module Main where

import qualified Control.Monad.Eff.JQuery as J
import           Control.Monad.Eff
import Control.Monad.Eff.Console
import DOM
import Data.Foreign (unsafeFromForeign)
import Prelude

import Ace (ace)
import Ace.Types (ACE())
import qualified Ace.Editor as Editor
import qualified Ace.EditSession as Session
import qualified Ace.Range as  Range

import Data.Either
import Data.Maybe
-- import Data.Array ((..), length, deleteAt, (!!), drop)
import Data.List
import Data.Tuple
import Control.Apply ((*>))
import Control.Monad.State.Trans
import Control.Monad.State.Class
import Control.Monad.Eff.Class

import Web (exprToJQuery, getPath)
import Parser
import Evaluator (evalPath1, Env(), Path(..), defsToEnv)
import AST
import Text.Parsing.Parser (ParseError(ParseError))
import Text.Parsing.Parser.Pos (Position(Position))



main = J.ready $ do
  J.select "#input"
    >>= J.on "change" (\_ _ -> startEvaluation)
    >>= J.on "keyup"  (\e _ -> if false {- isEnterKey e -} then startEvaluation else return unit)
  startEvaluation

type DOMEff = Eff (dom :: DOM, console :: CONSOLE, ace :: ACE)

type EvalState = { env :: Env, expr :: Expr, history :: List Expr }

type EvalM a = StateT EvalState DOMEff a

startEvaluation :: DOMEff Unit
startEvaluation = do
  editor <- Ace.edit "definitions" Ace.ace
  definitions <- Editor.getValue editor
  input       <- J.select "#input"       >>= getValue

  case parseExpr input of
    Left err   -> showInfo "Expression" (show err)
    Right expr -> do
      case defsToEnv <$> parseDefs definitions of
        Left err@(ParseError { position: (Position { line: line, column: column }) })  -> do
          showInfo "Definitions" (show err)
          markText (line - 1) column
        Right env -> do
          clearInfo
          void $ runStateT showEvaluationState { env: env, expr: expr, history: Nil }

markText :: Int -> Int -> DOMEff Unit
markText line column = do
  editor <- Ace.edit "definitions" Ace.ace
  session <- Editor.getSession editor
  rang <- Range.create line column 100000 100000
  Session.addMarker rang "syntaxError" "" false session

showEvaluationState :: EvalM Unit
showEvaluationState = do
  output <- liftEff $ prepareContainer "output"
  history <- liftEff $ prepareContainer "history"

  { env = env, expr = expr, history = histExprs } <- get :: EvalM EvalState
  liftEff $ print expr

  liftEff $ exprToJQuery expr >>= wrapInDiv "output" >>= flip J.append output
  showHistoryList histExprs >>= liftEff <<< flip J.append history

  -- liftEff (J.find ".binary, .app, .func, .list, .if" output)
  --   >>= makeClickable
  liftEff (J.find ".clickable" output)
    >>= addMouseOverListener
    >>= addClickListener
  liftEff (J.body >>= J.on "mouseover" (\_ _ -> removeMouseOver))

  liftEff $ return unit :: DOMEff Unit

forIndex :: forall m a b. (Applicative m) => (List a) -> (a -> Int -> m b) -> m (List b)
forIndex as f = zipWithA f as (0 .. (length as - 1))

showHistoryList :: (List Expr) -> EvalM J.JQuery
showHistoryList exprs = do
  box <- liftEff $ J.create "<div></div>" >>= J.addClass "historyBox"
  forIndex exprs $ \expr i -> do
    showHistory expr i >>= liftEff <<< wrapInDiv "vertical" >>= liftEff <<< flip J.append box
  return box

(!!!) :: forall a. (List a) -> Int -> a
(!!!) xs i = case xs !! i of Just x -> x

showHistory :: Expr -> Int -> EvalM J.JQuery
showHistory expr i = do
  history <- liftEff $ J.create "<div></div>" >>= J.addClass "history"
  liftEff $ exprToJQuery expr >>= flip J.append history
  es <- get :: EvalM EvalState
  let deleteHandler = \_ _ -> do
                        let es' = es { history = maybe es.history id (deleteAt i es.history) }
                        void $ runStateT showEvaluationState es'
  delete <- liftEff $ J.create "<button></button>"
    >>= J.setText "Delete"
    >>= J.addClass "delete"
    >>= J.on "click" deleteHandler
  liftEff $ J.append delete history
  let restoreHandler = \_ _ -> do
                         let es' = es { history = drop (i + 1) es.history, expr = es.history !!! i }
                         void $ runStateT showEvaluationState es'
  restore <- liftEff $ J.create "<button></button>"
    >>= J.setText "Restore"
    >>= J.addClass "restore"
    >>= J.on "click" restoreHandler
  liftEff $ J.append restore history
  return history

showInfo :: String -> String -> DOMEff Unit
showInfo origin msg = do
  info <- J.create "<p></p>"
    >>= J.addClass "info"
    >>= J.setText ("Error in " ++ origin ++ " => " ++ msg)
  clearInfo
  J.select "#info"
    >>= J.append info
  return unit

clearInfo :: DOMEff Unit
clearInfo = void $ J.select "#info" >>= J.clear

prepareContainer :: String -> DOMEff J.JQuery
prepareContainer name = do
  J.select ("#" ++ name ++ "-container") >>= J.clear

wrapInDiv :: String -> J.JQuery -> DOMEff J.JQuery
wrapInDiv name jq = do
  J.create "<div></div>" >>= J.addClass name >>= J.append jq

-- makeClickable :: J.JQuery -> EvalM Unit
-- makeClickable jq = do
--   { env = env, expr = expr } <- get
--   liftEff $ map (testEval env expr) jq
--   where
--   testEval :: Env -> Expr -> J.JQuery -> DOMEff Unit
--   testEval env expr jq = do
--     path <- getPath jq
--     case evalPath1 env path expr of
--       Left err -> void $ J.setAttr "title" (show err) jq
--       Right _  -> void $ J.addClass "clickable" jq *> J.setAttr "title" "" jq

addMouseOverListener :: J.JQuery -> EvalM J.JQuery
addMouseOverListener jq = liftEff $ J.on "mouseover" handler jq
  where
  handler :: J.JQueryEvent -> J.JQuery -> DOMEff Unit
  handler jEvent jq = do
    J.stopImmediatePropagation jEvent
    removeMouseOver
    J.addClass "mouseOver" jq
    return unit

addClickListener :: J.JQuery -> EvalM J.JQuery
addClickListener jq = do
  evaluationState <- get
  liftEff $ J.on "click" (handler evaluationState) jq
  where
  handler :: EvalState -> J.JQueryEvent -> J.JQuery -> DOMEff Unit
  handler evaluationState jEvent jq = do
    J.stopImmediatePropagation jEvent
    path <- getPath jq
    void $ runStateT (evalExpr path) evaluationState

removeMouseOver :: DOMEff Unit
removeMouseOver = void $ J.select ".mouseOver" >>= J.removeClass "mouseOver"

evalExpr :: Path -> EvalM Unit
evalExpr path = do
  { env = env, expr = expr } <- get
  liftEff $ print path
  case evalPath1 env path expr of
    -- Left msg   -> liftEff $ showInfo "execution" msg
    Right expr' -> do
      modify (\es -> es { expr = expr' })
      modify (\es -> es { history = expr : es.history })
      showEvaluationState

getValue :: J.JQuery -> DOMEff String
getValue jq = unsafeFromForeign <$> J.getValue jq
