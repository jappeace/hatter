-- | Declarative UI widget ADT.
--
-- Pure data describing the UI tree. Rendering is handled by
-- "HaskellMobile.Render", which traverses this tree and issues
-- FFI calls to the platform bridge.
module HaskellMobile.Widget
  ( FontConfig(..)
  , TextConfig(..)
  , ButtonConfig(..)
  , InputType(..)
  , TextInputConfig(..)
  , Widget(..)
  , WidgetStyle(..)
  , TextAlignment(..)
  , defaultStyle
  )
where

import Data.Text (Text)

-- | Font configuration for text-bearing widgets.
-- Only 'Text', 'Button', and 'TextInput' can carry a 'FontConfig'.
newtype FontConfig = FontConfig
  { fontSize :: Double
    -- ^ Font size in platform-native units (sp on Android, pt on iOS).
  } deriving (Show, Eq)

-- | Configuration for a read-only text label.
data TextConfig = TextConfig
  { tcLabel      :: Text
    -- ^ The text content to display.
  , tcFontConfig :: Maybe FontConfig
    -- ^ Optional font override.
  } deriving (Show, Eq)

-- | Configuration for a tappable button.
data ButtonConfig = ButtonConfig
  { bcLabel      :: Text
    -- ^ The button's label text.
  , bcAction     :: IO ()
    -- ^ Callback fired when the button is tapped.
  , bcFontConfig :: Maybe FontConfig
    -- ^ Optional font override.
  }

-- | The kind of on-screen keyboard to show for a 'TextInput'.
data InputType
  = InputText    -- ^ Default text keyboard.
  | InputNumber  -- ^ Numeric keyboard with decimal support.
  deriving (Show, Eq)

-- | Configuration for a text input field.
-- Follows a controlled-component pattern: Haskell owns the state.
data TextInputConfig = TextInputConfig
  { tiInputType :: InputType
    -- ^ Which on-screen keyboard to present.
  , tiHint      :: Text
    -- ^ Placeholder text shown when the field is empty.
  , tiValue     :: Text
    -- ^ Current text value (controlled by Haskell).
  , tiOnChange  :: Text -> IO ()
    -- ^ Callback fired when the user edits the field.
  , tiFontConfig :: Maybe FontConfig
    -- ^ Optional font override.
  }

-- | Horizontal text alignment for text-bearing widgets.
data TextAlignment
  = AlignStart   -- ^ Left-aligned (LTR) or right-aligned (RTL).
  | AlignCenter  -- ^ Centered horizontally.
  | AlignEnd     -- ^ Right-aligned (LTR) or left-aligned (RTL).
  deriving (Show, Eq)

-- | Visual style overrides for a widget node.
-- Font size is not here — it belongs in the config records of
-- text-bearing widgets ('TextConfig', 'ButtonConfig', 'TextInputConfig').
data WidgetStyle = WidgetStyle
  { wsPadding    :: Maybe Double
    -- ^ Uniform padding in platform-native units (px on Android, pt on iOS).
  , wsTextAlign  :: Maybe TextAlignment
    -- ^ Horizontal text alignment override.
  } deriving (Show, Eq)

-- | No style overrides — all fields are 'Nothing'.
defaultStyle :: WidgetStyle
defaultStyle = WidgetStyle
  { wsPadding    = Nothing
  , wsTextAlign  = Nothing
  }

-- | A declarative description of a UI element.
data Widget
  = Text TextConfig
    -- ^ A read-only text label.
  | Button ButtonConfig
    -- ^ A tappable button with a label and click handler.
  | TextInput TextInputConfig
    -- ^ A text input field.
  | Column [Widget]
    -- ^ A vertical container laying out children top-to-bottom.
  | Row [Widget]
    -- ^ A horizontal container laying out children left-to-right.
  | ScrollView [Widget]
    -- ^ A vertically scrollable container.
  | Styled WidgetStyle Widget
    -- ^ Apply visual style overrides to a child widget.
