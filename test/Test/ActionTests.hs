-- | Tests for Action/OnChange handles, Widget Eq, and incremental rendering.
module Test.ActionTests
  ( actionTests
  , widgetEqTests
  , incrementalRenderTests
  ) where

import Test.Tasty
import Test.Tasty.HUnit

import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Int (Int32)
import Data.List (isInfixOf, isPrefixOf, tails)
import Hatter
  ( Action(..)
  , OnChange(..)
  , createAction
  , createOnChange
  , newActionState
  , runActionM
  )
import Hatter.Widget
  ( defaultStyle
  , ButtonConfig(..)
  , InputType(..)
  , LayoutSettings(..)
  , TextConfig(..)
  , TextInputConfig(..)
  , Widget(..)
  , WidgetStyle(..)
  , Corners(..)
  , column
  , item
  , keyedItem
  , rounded
  , text
  )
import Hatter.Render
  ( RenderState(..)
  , RenderedNode(..)
  , renderedNodeId
  , renderWidget
  , dispatchEvent
  , dispatchTextEvent
  , reattachments
  , bindLazyRow
  , lazyItemKey
  )
import Test.Helpers (withActions, captureStderr)

-- | Tests for Action/OnChange handle equality and creation.
actionTests :: TestTree
actionTests = testGroup "Action"
  [ testCase "createAction produces unique IDs" $ do
      actionState <- newActionState
      (handleA, handleB) <- runActionM actionState $ do
        hA <- createAction (pure ())
        hB <- createAction (pure ())
        pure (hA, hB)
      assertBool "different actions should have different IDs" (handleA /= handleB)

  , testCase "createOnChange produces unique IDs" $ do
      actionState <- newActionState
      (handleA, handleB) <- runActionM actionState $ do
        hA <- createOnChange (\_ -> pure ())
        hB <- createOnChange (\_ -> pure ())
        pure (hA, hB)
      assertBool "different onChange handles should have different IDs" (handleA /= handleB)

  , testCase "Action and OnChange share ID space" $ do
      actionState <- newActionState
      (actionHandle, changeHandle) <- runActionM actionState $ do
        ah <- createAction (pure ())
        ch <- createOnChange (\_ -> pure ())
        pure (ah, ch)
      assertBool "action and onChange should have different IDs"
        (actionId actionHandle /= onChangeId changeHandle)

  , testCase "same Action handle equals itself" $ do
      actionState <- newActionState
      handle <- runActionM actionState $ createAction (pure ())
      handle @?= handle
  ]

-- | Tests for Widget Eq instance (enabled by opaque handles).
widgetEqTests :: TestTree
widgetEqTests = testGroup "WidgetEq"
  [ testCase "same widget with same handle is equal" $ do
      actionState <- newActionState
      handle <- runActionM actionState $ createAction (pure ())
      let widgetA = Button ButtonConfig { bcLabel = "tap", bcAction = handle, bcFontConfig = Nothing, bcTextColor = Nothing }
          widgetB = Button ButtonConfig { bcLabel = "tap", bcAction = handle, bcFontConfig = Nothing, bcTextColor = Nothing }
      widgetA @?= widgetB

  , testCase "same widget with different handles is not equal" $ do
      actionState <- newActionState
      (handleA, handleB) <- runActionM actionState $ do
        hA <- createAction (pure ())
        hB <- createAction (pure ())
        pure (hA, hB)
      let widgetA = Button ButtonConfig { bcLabel = "tap", bcAction = handleA, bcFontConfig = Nothing, bcTextColor = Nothing }
          widgetB = Button ButtonConfig { bcLabel = "tap", bcAction = handleB, bcFontConfig = Nothing, bcTextColor = Nothing }
      assertBool "different handles means different widgets" (widgetA /= widgetB)

  , testCase "Text widgets with same content are equal" $ do
      let widgetA = Text TextConfig { tcLabel = "hello", tcFontConfig = Nothing, tcTextColor = Nothing }
          widgetB = Text TextConfig { tcLabel = "hello", tcFontConfig = Nothing, tcTextColor = Nothing }
      widgetA @?= widgetB

  , testCase "Text widgets with different content are not equal" $ do
      let widgetA = Text TextConfig { tcLabel = "hello", tcFontConfig = Nothing, tcTextColor = Nothing }
          widgetB = Text TextConfig { tcLabel = "world", tcFontConfig = Nothing, tcTextColor = Nothing }
      assertBool "different labels means different widgets" (widgetA /= widgetB)

  , testCase "Column equality is structural" $ do
      let widgetA = column [Text TextConfig { tcLabel = "a", tcFontConfig = Nothing, tcTextColor = Nothing }]
          widgetB = column [Text TextConfig { tcLabel = "a", tcFontConfig = Nothing, tcTextColor = Nothing }]
          widgetC = column [Text TextConfig { tcLabel = "b", tcFontConfig = Nothing, tcTextColor = Nothing }]
      widgetA @?= widgetB
      assertBool "different children means different Column" (widgetA /= widgetC)
  ]

-- ---------------------------------------------------------------------------
-- Incremental rendering tests
-- ---------------------------------------------------------------------------

-- | Helper to extract children from a RenderedContainer.
childrenOf :: RenderedNode -> [RenderedNode]
childrenOf (RenderedContainer _ _ keyedChildren) = map snd keyedChildren
childrenOf _                                     = []

incrementalRenderTests :: TestTree
incrementalRenderTests = testGroup "Incremental rendering"
  [ testGroup "Node reuse"
      [ testCase "identical re-render retains same node ID" $ do
          ((), rs) <- withActions (pure ())
          let widget = Text TextConfig { tcLabel = "static", tcFontConfig = Nothing, tcTextColor = Nothing }
          renderWidget rs widget
          tree1 <- readIORef (rsRenderedTree rs)
          let nodeId1 = case tree1 of
                Just node -> renderedNodeId node
                Nothing   -> -1
          renderWidget rs widget
          tree2 <- readIORef (rsRenderedTree rs)
          let nodeId2 = case tree2 of
                Just node -> renderedNodeId node
                Nothing   -> -2
          nodeId1 @?= nodeId2

      , testCase "single child change updates in-place, preserving node IDs" $ do
          ((), rs) <- withActions (pure ())
          let widget1 = column
                [ Text TextConfig { tcLabel = "stable", tcFontConfig = Nothing, tcTextColor = Nothing }
                , Text TextConfig { tcLabel = "will change", tcFontConfig = Nothing, tcTextColor = Nothing }
                ]
          renderWidget rs widget1
          tree1 <- readIORef (rsRenderedTree rs)
          (child0Id1, child1Id1) <- case tree1 of
            Just node -> case childrenOf node of
              [c0, c1] -> pure (renderedNodeId c0, renderedNodeId c1)
              _        -> assertFailure "expected 2 children" >> pure (-1, -1)
            Nothing -> assertFailure "expected rendered tree" >> pure (-1, -1)
          let widget2 = column
                [ Text TextConfig { tcLabel = "stable", tcFontConfig = Nothing, tcTextColor = Nothing }
                , Text TextConfig { tcLabel = "changed!", tcFontConfig = Nothing, tcTextColor = Nothing }
                ]
          renderWidget rs widget2
          tree2 <- readIORef (rsRenderedTree rs)
          (child0Id2, child1Id2) <- case tree2 of
            Just node -> case childrenOf node of
              [c0, c1] -> pure (renderedNodeId c0, renderedNodeId c1)
              _        -> assertFailure "expected 2 children" >> pure (-1, -1)
            Nothing -> assertFailure "expected rendered tree" >> pure (-1, -1)
          -- Both children keep same node IDs (in-place diff via setStrProp)
          child0Id1 @?= child0Id2
          child1Id1 @?= child1Id2

      , testCase "callback-only handle change updates in-place" $ do
          ref <- newIORef ("none" :: String)
          ((handle1, handle2), rs) <- withActions $ do
            h1 <- createAction (writeIORef ref "action1")
            h2 <- createAction (writeIORef ref "action2")
            pure (h1, h2)
          -- Render button with handle1
          let widget1 = Button ButtonConfig
                { bcLabel = "same label", bcAction = handle1, bcFontConfig = Nothing, bcTextColor = Nothing }
          renderWidget rs widget1
          tree1 <- readIORef (rsRenderedTree rs)
          let nodeId1 = case tree1 of
                Just node -> renderedNodeId node
                Nothing   -> -1
          -- Render same label but with handle2 (different Eq)
          let widget2 = Button ButtonConfig
                { bcLabel = "same label", bcAction = handle2, bcFontConfig = Nothing, bcTextColor = Nothing }
          renderWidget rs widget2
          tree2 <- readIORef (rsRenderedTree rs)
          let nodeId2 = case tree2 of
                Just node -> renderedNodeId node
                Nothing   -> -2
          -- In-place diff: same native node, handler updated via setHandler
          nodeId1 @?= nodeId2
          -- Dispatch handle2 — should fire action2
          dispatchEvent rs (actionId handle2)
          result <- readIORef ref
          result @?= "action2"

      , testCase "same handle reuses node" $ do
          ref <- newIORef ("none" :: String)
          (handle, rs) <- withActions $
            createAction (writeIORef ref "fired")
          -- Render button with handle
          let widget1 = Button ButtonConfig
                { bcLabel = "same label", bcAction = handle, bcFontConfig = Nothing, bcTextColor = Nothing }
          renderWidget rs widget1
          tree1 <- readIORef (rsRenderedTree rs)
          let nodeId1 = case tree1 of
                Just node -> renderedNodeId node
                Nothing   -> -1
          -- Re-render identical widget
          renderWidget rs widget1
          tree2 <- readIORef (rsRenderedTree rs)
          let nodeId2 = case tree2 of
                Just node -> renderedNodeId node
                Nothing   -> -2
          -- Same handle, same label → reused node
          nodeId1 @?= nodeId2
          -- Dispatch still works
          dispatchEvent rs (actionId handle)
          result <- readIORef ref
          result @?= "fired"

      , testCase "adding a child to container" $ do
          ((), rs) <- withActions (pure ())
          let widget1 = column
                [ Text TextConfig { tcLabel = "first", tcFontConfig = Nothing, tcTextColor = Nothing } ]
          renderWidget rs widget1
          tree1 <- readIORef (rsRenderedTree rs)
          existingChildId <- case tree1 of
            Just node -> case childrenOf node of
              [c0] -> pure (renderedNodeId c0)
              _    -> assertFailure "expected 1 child" >> pure (-1)
            Nothing -> assertFailure "expected rendered tree" >> pure (-1)
          let widget2 = column
                [ Text TextConfig { tcLabel = "first", tcFontConfig = Nothing, tcTextColor = Nothing }
                , Text TextConfig { tcLabel = "second", tcFontConfig = Nothing, tcTextColor = Nothing }
                ]
          renderWidget rs widget2
          tree2 <- readIORef (rsRenderedTree rs)
          case tree2 of
            Just node -> case childrenOf node of
              [c0, c1] -> do
                -- First child retained
                renderedNodeId c0 @?= existingChildId
                -- Second child is new (different ID)
                assertBool "new child should have different ID"
                  (renderedNodeId c1 /= existingChildId)
              _ -> assertFailure "expected 2 children"
            Nothing -> assertFailure "expected rendered tree"

      , testCase "removing a child from container" $ do
          ((), rs) <- withActions (pure ())
          let widget1 = column
                [ Text TextConfig { tcLabel = "a", tcFontConfig = Nothing, tcTextColor = Nothing }
                , Text TextConfig { tcLabel = "b", tcFontConfig = Nothing, tcTextColor = Nothing }
                ]
          renderWidget rs widget1
          let widget2 = column
                [ Text TextConfig { tcLabel = "a", tcFontConfig = Nothing, tcTextColor = Nothing } ]
          renderWidget rs widget2
          tree2 <- readIORef (rsRenderedTree rs)
          let children2 = childrenOf (maybe (error "no tree") id tree2)
          length children2 @?= 1

      , testCase "root type change triggers new root node" $ do
          (handle, rs) <- withActions $
            createAction (pure ())
          let widget1 = Text TextConfig { tcLabel = "text", tcFontConfig = Nothing, tcTextColor = Nothing }
          renderWidget rs widget1
          tree1 <- readIORef (rsRenderedTree rs)
          let nodeId1 = case tree1 of
                Just node -> renderedNodeId node
                Nothing   -> -1
          let widget2 = Button ButtonConfig
                { bcLabel = "button", bcAction = handle, bcFontConfig = Nothing, bcTextColor = Nothing }
          renderWidget rs widget2
          tree2 <- readIORef (rsRenderedTree rs)
          let nodeId2 = case tree2 of
                Just node -> renderedNodeId node
                Nothing   -> -2
          assertBool "different widget type should produce new node ID"
            (nodeId1 /= nodeId2)

      , testCase "styled unchanged keeps same node ID" $ do
          ((), rs) <- withActions (pure ())
          let style = defaultStyle { wsPadding = Just 10.0 }
              widget = Styled style (Text TextConfig { tcLabel = "styled", tcFontConfig = Nothing, tcTextColor = Nothing })
          renderWidget rs widget
          tree1 <- readIORef (rsRenderedTree rs)
          let nodeId1 = case tree1 of
                Just node -> renderedNodeId node
                Nothing   -> -1
          renderWidget rs widget
          tree2 <- readIORef (rsRenderedTree rs)
          let nodeId2 = case tree2 of
                Just node -> renderedNodeId node
                Nothing   -> -2
          nodeId1 @?= nodeId2

      , testCase "styled child change updates in-place" $ do
          ((), rs) <- withActions (pure ())
          let style = defaultStyle { wsPadding = Just 10.0 }
              widget1 = Styled style (Text TextConfig { tcLabel = "before", tcFontConfig = Nothing, tcTextColor = Nothing })
          renderWidget rs widget1
          tree1 <- readIORef (rsRenderedTree rs)
          let nodeId1 = case tree1 of
                Just node -> renderedNodeId node
                Nothing   -> -1
          let widget2 = Styled style (Text TextConfig { tcLabel = "after", tcFontConfig = Nothing, tcTextColor = Nothing })
          renderWidget rs widget2
          tree2 <- readIORef (rsRenderedTree rs)
          let nodeId2 = case tree2 of
                Just node -> renderedNodeId node
                Nothing   -> -2
          -- In-place Text diff: same node, label updated via setStrProp
          nodeId1 @?= nodeId2

      , testCase "styled child type change reapplies style" $ do
          (clickAction, rs) <- withActions $
            createAction (pure ())
          let style = defaultStyle { wsPadding = Just 10.0 }
              widget1 = Styled style (Text TextConfig { tcLabel = "txt", tcFontConfig = Nothing, tcTextColor = Nothing })
          renderWidget rs widget1
          -- Re-render with different child type but same style
          let widget2 = Styled style (Button (ButtonConfig "btn" clickAction Nothing Nothing))
          ((), stderrOutput) <- captureStderr $ renderWidget rs widget2
          -- applyStyle must fire setNumProp for padding on the new node
          assertBool
            ("setNumProp for padding should appear in stderr, got: " ++ stderrOutput)
            ("setNumProp" `isInfixOf` stderrOutput && "10.00" `isInfixOf` stderrOutput)

      , testCase "a style field gone from a reused node is put back" $ do
          ((), rs) <- withActions (pure ())
          let row = Text TextConfig { tcLabel = "row", tcFontConfig = Nothing, tcTextColor = Nothing }
          renderWidget rs (Styled defaultStyle { wsMargin = Just 8.0 } row)
          ((), stderrOutput) <- captureStderr $ renderWidget rs (Styled defaultStyle row)
          assertBool
            ("the margin should go back to unset, got: " ++ stderrOutput)
            ("setNumProp" `isInfixOf` stderrOutput && "nan" `isInfixOf` stderrOutput)

      , testCase "the same corners round what's on a widget too, others only its background" $ do
          ((), rs) <- withActions (pure ())
          let shaped corners = Styled defaultStyle { wsCorners = Just corners } (text "bubble")
              -- What the line sets the property to, as C printed it.
              value l = case [rest | rest <- tails l, "value=" `isPrefixOf` rest] of
                rest : _ -> takeWhile (/= ')') (drop (length ("value=" :: String)) rest)
                [] -> ""
              sets prop ok out = any (\l -> ("prop=" ++ prop ++ ",") `isInfixOf` l && ok (value l)) (lines out)
              -- C prints NaN as nan, -nan or -nan(ind).
              unset = ("nan" `isInfixOf`)
              -- The radius, which clips, and the top left corner of the background.
              rounds radius corner out = sets "19" (== radius) out && sets "26" corner out
          ((), same) <- captureStderr (renderWidget rs (shaped (rounded 8)))
          assertBool same (rounds "8.00" unset same)
          ((), each) <- captureStderr (renderWidget rs (shaped (Corners 1 2 3 4)))
          assertBool each (rounds "0.00" (== "1.00") each)
      ]

  , testGroup "TextInput in-place update"
      [ testCase "TextInput value change preserves native node" $ do
          (changeHandle, rs) <- withActions $
            createOnChange (\_ -> pure ())
          let widget1 = TextInput TextInputConfig
                { tiInputType = InputNumber, tiHint = "% of 1RM", tiValue = ""
                , tiOnChange = changeHandle, tiFontConfig = Nothing, tiTextColor = Nothing, tiAutoFocus = False }
          renderWidget rs widget1
          tree1 <- readIORef (rsRenderedTree rs)
          let nodeId1 = case tree1 of
                Just node -> renderedNodeId node
                Nothing   -> -1
          -- Re-render with a different value (simulates user typing)
          let widget2 = TextInput TextInputConfig
                { tiInputType = InputNumber, tiHint = "% of 1RM", tiValue = "80"
                , tiOnChange = changeHandle, tiFontConfig = Nothing, tiTextColor = Nothing, tiAutoFocus = False }
          renderWidget rs widget2
          tree2 <- readIORef (rsRenderedTree rs)
          let nodeId2 = case tree2 of
                Just node -> renderedNodeId node
                Nothing   -> -2
          -- Same native node — in-place update, not destroy+create
          nodeId1 @?= nodeId2

      , testCase "TextInput hint change preserves native node" $ do
          (changeHandle, rs) <- withActions $
            createOnChange (\_ -> pure ())
          let widget1 = TextInput TextInputConfig
                { tiInputType = InputText, tiHint = "old hint", tiValue = ""
                , tiOnChange = changeHandle, tiFontConfig = Nothing, tiTextColor = Nothing, tiAutoFocus = False }
          renderWidget rs widget1
          tree1 <- readIORef (rsRenderedTree rs)
          let nodeId1 = case tree1 of
                Just node -> renderedNodeId node
                Nothing   -> -1
          let widget2 = TextInput TextInputConfig
                { tiInputType = InputText, tiHint = "new hint", tiValue = ""
                , tiOnChange = changeHandle, tiFontConfig = Nothing, tiTextColor = Nothing, tiAutoFocus = False }
          renderWidget rs widget2
          tree2 <- readIORef (rsRenderedTree rs)
          let nodeId2 = case tree2 of
                Just node -> renderedNodeId node
                Nothing   -> -2
          nodeId1 @?= nodeId2

      , testCase "TextInput callback survives in-place update" $ do
          ref <- newIORef ("" :: String)
          (changeHandle, rs) <- withActions $
            createOnChange (\t -> writeIORef ref (show t))
          let widget1 = TextInput TextInputConfig
                { tiInputType = InputNumber, tiHint = "weight", tiValue = ""
                , tiOnChange = changeHandle, tiFontConfig = Nothing, tiTextColor = Nothing, tiAutoFocus = False }
          renderWidget rs widget1
          -- Simulate text change followed by re-render (new value)
          let widget2 = TextInput TextInputConfig
                { tiInputType = InputNumber, tiHint = "weight", tiValue = "80"
                , tiOnChange = changeHandle, tiFontConfig = Nothing, tiTextColor = Nothing, tiAutoFocus = False }
          renderWidget rs widget2
          -- Callback should still work after in-place diff
          dispatchTextEvent rs (onChangeId changeHandle) "95"
          val <- readIORef ref
          val @?= show ("95" :: String)

      , testCase "TextInput inside Column preserves node on value change" $ do
          (changeHandle, rs) <- withActions $
            createOnChange (\_ -> pure ())
          let mkWidget value = column
                [ Text TextConfig { tcLabel = "header", tcFontConfig = Nothing, tcTextColor = Nothing }
                , TextInput TextInputConfig
                    { tiInputType = InputNumber, tiHint = "% of 1RM", tiValue = value
                    , tiOnChange = changeHandle, tiFontConfig = Nothing, tiTextColor = Nothing, tiAutoFocus = False }
                , Text TextConfig { tcLabel = "footer", tcFontConfig = Nothing, tcTextColor = Nothing }
                ]
          renderWidget rs (mkWidget "")
          tree1 <- readIORef (rsRenderedTree rs)
          let inputNodeId1 = case tree1 of
                Just node -> case childrenOf node of
                  [_, inputNode, _] -> renderedNodeId inputNode
                  _                 -> -1
                Nothing -> -1
          renderWidget rs (mkWidget "80")
          tree2 <- readIORef (rsRenderedTree rs)
          let inputNodeId2 = case tree2 of
                Just node -> case childrenOf node of
                  [_, inputNode, _] -> renderedNodeId inputNode
                  _                 -> -2
                Nothing -> -2
          -- TextInput node is preserved (not destroyed+recreated)
          inputNodeId1 @?= inputNodeId2

      , testCase "inserting child at position 0 preserves keyed TextInput (issue #186)" $ do
          ((changeHandle, clickAction), rs) <- withActions $ do
            ch <- createOnChange (\_ -> pure ())
            ca <- createAction (pure ())
            pure (ch, ca)
          -- Render: [TextInput(key=10), Button(key=20)]
          let textInput = TextInput TextInputConfig
                { tiInputType = InputText, tiHint = "enter text", tiValue = ""
                , tiOnChange = changeHandle, tiFontConfig = Nothing, tiTextColor = Nothing, tiAutoFocus = False }
              toggleBtn = Button ButtonConfig
                { bcLabel = "toggle", bcAction = clickAction, bcFontConfig = Nothing, bcTextColor = Nothing }
              widget1 = Column LayoutSettings
                { lsWidgets = [keyedItem 10 textInput, keyedItem 20 toggleBtn]
                , lsScrollable = False }
          renderWidget rs widget1
          tree1 <- readIORef (rsRenderedTree rs)
          let inputNodeId1 = case tree1 of
                Just node -> case childrenOf node of
                  (inputNode : _) -> renderedNodeId inputNode
                  _               -> -1
                Nothing -> -1
          -- Re-render: [Banner(unkeyed), TextInput(key=10), Button(key=20)]
          let banner = Text TextConfig { tcLabel = "Banner", tcFontConfig = Nothing, tcTextColor = Nothing }
              widget2 = Column LayoutSettings
                { lsWidgets = [item banner, keyedItem 10 textInput, keyedItem 20 toggleBtn]
                , lsScrollable = False }
          renderWidget rs widget2
          tree2 <- readIORef (rsRenderedTree rs)
          let inputNodeId2 = case tree2 of
                Just node -> case childrenOf node of
                  (_ : inputNode : _) -> renderedNodeId inputNode
                  _                   -> -2
                Nothing -> -2
          -- TextInput keeps same native node ID via explicit key matching
          inputNodeId1 @?= inputNodeId2

      , testCase "explicit keyed children survive reordering" $ do
          ((), rs) <- withActions (pure ())
          let itemA = keyedItem 1 (text "A")
              itemB = keyedItem 2 (text "B")
          -- Render: [A, B]
          renderWidget rs (Column LayoutSettings { lsWidgets = [itemA, itemB], lsScrollable = False })
          tree1 <- readIORef (rsRenderedTree rs)
          let (childA1, childB1) = case tree1 of
                Just node -> case childrenOf node of
                  [cA, cB] -> (renderedNodeId cA, renderedNodeId cB)
                  _        -> (-1, -1)
                Nothing -> (-1, -1)
          -- Reorder: [B, A]
          renderWidget rs (Column LayoutSettings { lsWidgets = [itemB, itemA], lsScrollable = False })
          tree2 <- readIORef (rsRenderedTree rs)
          let (childB2, childA2) = case tree2 of
                Just node -> case childrenOf node of
                  [cB, cA] -> (renderedNodeId cB, renderedNodeId cA)
                  _        -> (-2, -2)
                Nothing -> (-2, -2)
          -- Each child kept its native node ID despite reordering
          childA1 @?= childA2
          childB1 @?= childB2

      , testCase "only children after a change are taken out and added again" $ do
          reattachments [1, 2, 3] [1, 2, 3, 4] @?= ([], [4])
          reattachments [1, 2, 3] [1, 9, 2, 3] @?= ([2, 3], [9, 2, 3])
          reattachments [1, 2] [2, 1] @?= ([1, 2], [2, 1])
          reattachments [1, 2] [1, 2] @?= ([], [])

      , testCase "a lazy column renders its items into the rows asked for" $ do
          ((), rs) <- withActions (pure ())
          renderWidget rs (LazyColumn (map (item . text) ["A", "B", "C"]))
          tree <- readIORef (rsRenderedTree rs)
          listId <- case tree of
            Just (RenderedLazy _ nodeId _) -> pure nodeId
            _ -> assertFailure "not a lazy column" >> pure 0
          row <- bindLazyRow rs listId 0 0
          assertBool "a new row" (row /= 0)
          bindLazyRow rs listId row 2 >>= (@?= row)
          bindLazyRow rs listId row 3 >>= (@?= 0)
          bindLazyRow rs (listId + 1000) 0 0 >>= (@?= 0)

      , testCase "a lazy column makes only the items of its rows, also when what's around it changes" $ do
          ((), rs) <- withActions (pure ())
          let page label = column
                [ text label
                , LazyColumn [keyedItem 0 (text "A"), keyedItem 1 (errorWithoutStackTrace "made an item no row shows")]
                ]
          renderWidget rs (page "x")
          listId <- lazyIn rs
          _ <- bindLazyRow rs listId 0 0
          renderWidget rs (page "y")

      , testCase "a lazy column shows a changed item in its row, and new keys to the platform" $ do
          ((), rs) <- withActions (pure ())
          renderWidget rs (column [LazyColumn [keyedItem 0 (text "A")]])
          listId <- lazyIn rs
          _ <- bindLazyRow rs listId 0 0
          let counted = (("setNumProp(node=" ++ show listId ++ ",") `isInfixOf`)
          ((), changed) <- captureStderr (renderWidget rs (column [LazyColumn [keyedItem 0 (text "B")]]))
          assertBool "the row shows the new item" ("value=\"B\"" `isInfixOf` changed)
          assertBool "the platform isn't asked to show the items again" (not (counted changed))
          ((), added) <- captureStderr (renderWidget rs (column [LazyColumn [keyedItem 0 (text "B"), keyedItem 1 (text "C")]]))
          assertBool "the platform is told of the new item" (counted added)

      , testCase "a lazy column's items are known by their keys, else their positions" $ do
          ((), rs) <- withActions (pure ())
          let listOf items = do
                renderWidget rs (LazyColumn items)
                tree <- readIORef (rsRenderedTree rs)
                case tree of
                  Just (RenderedLazy _ nodeId _) -> pure nodeId
                  _ -> assertFailure "not a lazy column" >> pure 0
          keyed <- listOf [keyedItem 7 (text "A"), keyedItem 9 (text "B")]
          mapM (lazyItemKey rs keyed) [0, 1] >>= (@?= [7, 9])
          plain <- listOf (map (item . text) ["A", "B"])
          lazyItemKey rs plain 1 >>= (@?= 1)
      ]
  ]

-- | The node of the lazy column in the column rendered last.
lazyIn :: RenderState -> IO Int32
lazyIn rs = readIORef (rsRenderedTree rs) >>= \case
  Just (RenderedContainer _ _ children)
    | [nodeId] <- [nodeId | (_, RenderedLazy _ nodeId _) <- children] -> pure nodeId
  _ -> assertFailure "no lazy column in a column" >> pure 0
