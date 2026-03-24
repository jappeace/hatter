-- | Declarative UI widget ADT.
--
-- Pure data describing the UI tree. Rendering is handled by
-- "HaskellMobile.Render", which traverses this tree and issues
-- FFI calls to the platform bridge.
module HaskellMobile.Widget
  ( Widget(..)
  , text
  , button
  , column
  , row
  )
where

import Data.Text (Text)

-- | A declarative description of a UI element.
data Widget
  = WText Text
    -- ^ A read-only text label.
  | WButton Text (IO ())
    -- ^ A tappable button with a label and click handler.
  | WColumn [Widget]
    -- ^ A vertical container laying out children top-to-bottom.
  | WRow [Widget]
    -- ^ A horizontal container laying out children left-to-right.

-- | Construct a text label widget.
text :: Text -> Widget
text = WText

-- | Construct a button widget with a label and click handler.
button :: Text -> IO () -> Widget
button = WButton

-- | Construct a vertical container widget.
column :: [Widget] -> Widget
column = WColumn

-- | Construct a horizontal container widget.
row :: [Widget] -> Widget
row = WRow
