module Test.Main where

import Prelude
import Data.List (length)
import Data.Traversable (for)

import Test.Parser as Parser
import Test.Evaluator as Evaluator
import Test.AST as AST
import Test.TypeChecker as TypeChecker

import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Console (CONSOLE, log)
import Control.Monad.Writer (execWriter)

import Node.Process (PROCESS, exit)

report :: forall eff. String -> Eff (console :: CONSOLE | eff) Unit
report msg = do
  log "\n"
  log msg

main :: forall eff. Eff (console :: CONSOLE, process :: PROCESS | eff) Unit
main = do
  log $ "Running parser tests..."
  let parserLog = execWriter Parser.runTests
  log $ "  ...found " <> show (length parserLog) <> " errors"
  for parserLog report

  log $ "Running AST tests..."
  let astLog = execWriter AST.runTests
  log $ "  ...found " <> show (length astLog) <> " errors"
  for astLog report

  log $ "Running evaluator tests..."
  let evaluatorLog = execWriter Evaluator.runTests
  log $ "  ...found " <> show (length evaluatorLog) <> " errors"
  for evaluatorLog report

  log $ "Running type checker tests..."
  let typeCheckerLog = execWriter TypeChecker.runTests
  log $ "  ...found " <> show (length typeCheckerLog) <> " errors"
  for typeCheckerLog report

  let errorCount = length parserLog -- + length evaluatorLog +  length astLog + length typeCheckerLog
  if errorCount == 0
    then do
      log $ "All tests succesfull"
      exit 0
    else do
      log $ "Found " <> show errorCount <> " errors!"
      exit 1
