module Main where

import Test.Tasty
import Test.Tasty.QuickCheck as QC
import Test.Tasty.HUnit

import Data.List (sort)
import Data.IORef (newIORef, readIORef, modifyIORef')
import Foreign.C.String (newCString, peekCString)
import Foreign.Marshal.Alloc (free)
import qualified HaskellMobile
import HaskellMobile.Lifecycle
  ( LifecycleEvent(..)
  , lifecycleFromInt
  , lifecycleToInt
  , setLifecycleCallback
  , haskellOnLifecycle
  )

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Tests" [qcProps, unitTests, lifecycleTests]

qcProps :: TestTree
qcProps = testGroup "(checked by QuickCheck)"
  [ QC.testProperty "sort == sort . reverse" $
      \list -> sort (list :: [Int]) == sort (reverse list)
  , QC.testProperty "Fermat's little theorem" $
      \x -> ((x :: Integer)^zeven  - x) `mod` zeven == 0
  ]
  where
    zeven :: Integer
    zeven = 7

oneTwoThree :: [Int]
oneTwoThree = [1, 2, 3]

unitTests :: TestTree
unitTests = testGroup "Unit tests"
  [ testCase "List comparison (different length)" $
       oneTwoThree `compare` [1,2] @?= GT

  -- the following test does not hold
  , testCase "List comparison (same length)" $
      oneTwoThree `compare` [1,2,3] @?= EQ
  , testCase "run main" $ do
      HaskellMobile.main
  , testCase "haskellGreet returns correct greeting" $ do
      cname <- newCString "World"
      cresult <- HaskellMobile.haskellGreet cname
      result <- peekCString cresult
      free cresult
      free cname
      result @?= "Hello from Haskell, World!"
  , testCase "haskellGreet with different input" $ do
      cname <- newCString "Android"
      cresult <- HaskellMobile.haskellGreet cname
      result <- peekCString cresult
      free cresult
      free cname
      result @?= "Hello from Haskell, Android!"
  ]

allEvents :: [LifecycleEvent]
allEvents = [Create, Start, Resume, Pause, Stop, Destroy, LowMemory]

lifecycleTests :: TestTree
lifecycleTests = testGroup "Lifecycle"
  [ testCase "lifecycleToInt produces sequential codes 0-6" $
      map lifecycleToInt allEvents @?= [0, 1, 2, 3, 4, 5, 6]
  , testCase "lifecycleFromInt roundtrips for all events" $
      mapM_ (\event ->
        lifecycleFromInt (lifecycleToInt event) @?= Just event
      ) allEvents
  , testCase "lifecycleFromInt returns Nothing for unknown codes" $ do
      lifecycleFromInt 7 @?= Nothing
      lifecycleFromInt (-1) @?= Nothing
      lifecycleFromInt 100 @?= Nothing
  , testCase "setLifecycleCallback + haskellOnLifecycle dispatches correctly" $ do
      ref <- newIORef ([] :: [LifecycleEvent])
      setLifecycleCallback $ \event -> modifyIORef' ref (++ [event])
      haskellOnLifecycle 2
      received <- readIORef ref
      received @?= [Resume]
  , testCase "unknown event codes are silently ignored" $ do
      ref <- newIORef (0 :: Int)
      setLifecycleCallback $ \_ -> modifyIORef' ref (+ 1)
      haskellOnLifecycle 99
      haskellOnLifecycle (-1)
      count <- readIORef ref
      count @?= 0
  , testCase "all 7 event types received in order" $ do
      ref <- newIORef ([] :: [LifecycleEvent])
      setLifecycleCallback $ \event -> modifyIORef' ref (++ [event])
      mapM_ (haskellOnLifecycle . lifecycleToInt) allEvents
      received <- readIORef ref
      received @?= allEvents
  ]
