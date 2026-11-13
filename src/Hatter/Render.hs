{-# LANGUAGE ImportQualifiedPost #-}
-- | Rendering engine that converts a 'Widget' tree into native UI
-- via the C bridge.
--
-- Uses an incremental diff strategy: on each render, the new widget
-- tree is compared (via derived 'Eq') against the previously rendered
-- tree.  Only changed subtrees are destroyed and recreated; unchanged
-- nodes keep their native views.
--
-- Callbacks are stored in a shared 'ActionState' registry that is
-- never cleared during rendering — handles inside widget configs
-- reference stable entries in the registry.
module Hatter.Render
  ( RenderState(..)
  , RenderedNode(..)
  , newRenderState
  , renderWidget
  , resetRender
  , dispatchEvent
  , dispatchTextEvent
  , reattachments
  , bindLazyRow
  , lazyItemKey
  , dispatchScrollEvent
  )
where

import           Control.Monad         (unless, when)
import           Data.Foldable         (asum)
import           Data.Int              (Int32)
import           Data.IntMap.Strict    (IntMap)
import qualified Data.IntMap.Strict    as IntMap
import           Data.IntSet           (IntSet)
import qualified Data.IntSet           as IntSet
import           Data.IORef            (IORef, newIORef, readIORef, writeIORef)
import           Data.List             (sortBy)
import           Data.Maybe            (isJust, isNothing)
import           Data.Ord              (comparing)
import           Data.Sequence         (Seq)
import qualified Data.Sequence         as Seq
import           Data.Text             (Text, pack)
import           Hatter.Action         (Action (..), ActionState, OnChange (..),
                                        OnScroll (..), lookupAction,
                                        lookupScrollAction, lookupTextAction)
import           Hatter.Animation      (AnimationState (..), registerTween)
import           Hatter.Widget         (AnimatedConfig (..), ButtonConfig (..),
                                        Color (..), Corners (..),
                                        FontConfig (..), FontFamily (..),
                                        FontSlant (..), FontWeight (..),
                                        ImageConfig (..), ImageSource (..),
                                        InputType (..), Keyframe (..),
                                        LayoutItem (..), LayoutSettings (..),
                                        MapViewConfig (..), ResourceName (..),
                                        ScaleType (..), SelfAlignment (..),
                                        TextAlignment (..), TextConfig (..),
                                        TextInputConfig (..),
                                        WebViewConfig (..), Widget (..),
                                        WidgetStyle (..), colorToHex,
                                        normalizeAnimated, resolveKeyAtIndex)
import qualified Unwitch.Convert.Int   as Int
import qualified Unwitch.Convert.Int32 as Int32

import qualified Hatter.UIBridge       as Bridge
import           System.IO             (hPutStrLn, stderr)

-- ---------------------------------------------------------------------------
-- Rendered tree: retained structure for incremental diffing
-- ---------------------------------------------------------------------------

-- | A snapshot of a rendered widget, retaining the widget value
-- (for equality comparison) and native node IDs.
data RenderedNode
  = RenderedLeaf
      Widget         -- ^ Widget value for equality comparison.
      Int32          -- ^ Native node ID from the platform bridge.
  | RenderedContainer
      Widget              -- ^ Widget value (Column/Row/Stack with children).
      Int32               -- ^ Native node ID.
      [(Int, RenderedNode)] -- ^ Rendered children, keyed by resolved WidgetKey value.
  | RenderedStyled
      Widget         -- ^ Widget value (Styled wrapper).
      WidgetStyle    -- ^ Applied style (for change detection).
      RenderedNode   -- ^ Child (Styled doesn't own a native node).
  | RenderedAnimated
      Widget         -- ^ Full Animated widget (Animated config child) for Eq comparison.
      RenderedNode   -- ^ Child's rendered node (owns native node IDs).
  | RenderedTappable
      Widget         -- ^ Widget value (Tappable or LongPressable wrapper).
      RenderedNode   -- ^ Child (neither owns a native node).
  | RenderedLazy
      Widget         -- ^ Widget value (LazyColumn with its items).
      Int32          -- ^ Native node ID of the list.
      LazyRows       -- ^ What its rows show, filled as the platform asks.

-- | A 'LazyColumn''s items, and the rows the platform made for it so far,
-- each a native column node with the item it shows last.
data LazyRows = LazyRows
  { lrItems :: IORef (Seq LayoutItem)
  , lrRows  :: IORef (IntMap RenderedNode)
  }

-- | Get the native node ID for a rendered node.
-- 'RenderedStyled' follows through to its child's node ID.
renderedNodeId :: RenderedNode -> Int32
renderedNodeId (RenderedLeaf _ nodeId)        = nodeId
renderedNodeId (RenderedContainer _ nodeId _) = nodeId
renderedNodeId (RenderedStyled _ _ child)     = renderedNodeId child
renderedNodeId (RenderedAnimated _ child)     = renderedNodeId child
renderedNodeId (RenderedTappable _ child)     = renderedNodeId child
renderedNodeId (RenderedLazy _ nodeId _)      = nodeId

-- | Get the widget value for a rendered node.
renderedWidget :: RenderedNode -> Widget
renderedWidget (RenderedLeaf widget _)        = widget
renderedWidget (RenderedContainer widget _ _) = widget
renderedWidget (RenderedStyled widget _ _)    = widget
renderedWidget (RenderedAnimated widget _)    = widget
renderedWidget (RenderedTappable widget _)    = widget
renderedWidget (RenderedLazy widget _ _)      = widget

-- | Update the widget stored in a RenderedNode to reflect an animation target.
-- The native node ID and children are preserved; only the bookkeeping fields
-- (widget, style) change so the next diff sees the post-animation state.
updateRenderedTarget :: Widget -> RenderedNode -> RenderedNode
updateRenderedTarget target (RenderedLeaf _ nodeId) =
  RenderedLeaf target nodeId
updateRenderedTarget target (RenderedContainer _ nodeId children) =
  RenderedContainer target nodeId children
updateRenderedTarget (Styled newStyle _) (RenderedStyled _ _ child) =
  RenderedStyled (Styled newStyle (renderedWidget child)) newStyle child
updateRenderedTarget target (RenderedStyled _ oldStyle child) =
  RenderedStyled target oldStyle child
updateRenderedTarget target (RenderedAnimated _ child) =
  RenderedAnimated target child
updateRenderedTarget target (RenderedTappable _ child) =
  RenderedTappable target child
updateRenderedTarget target (RenderedLazy _ nodeId rows) =
  RenderedLazy target nodeId rows

-- ---------------------------------------------------------------------------
-- Render state
-- ---------------------------------------------------------------------------

-- | Mutable state for the rendering engine.
-- Holds a reference to the shared 'ActionState' callback registry
-- and the previously rendered tree for incremental diffing.
data RenderState = RenderState
  { rsActionState    :: ActionState
    -- ^ Shared callback registry (never cleared during rendering).
  , rsRenderedTree   :: IORef (Maybe RenderedNode)
    -- ^ The previously rendered tree, or 'Nothing' for the first render.
  , rsAnimationState :: AnimationState
    -- ^ Mutable animation tween registry.
  }

-- | Create a fresh 'RenderState' wrapping the given 'ActionState'
-- and 'AnimationState'.
newRenderState :: ActionState -> AnimationState -> IO RenderState
newRenderState actionState animState = do
  renderedTree <- newIORef Nothing
  pure RenderState
    { rsActionState    = actionState
    , rsRenderedTree   = renderedTree
    , rsAnimationState = animState
    }

-- ---------------------------------------------------------------------------
-- Bridge helpers
-- ---------------------------------------------------------------------------

-- | Map an 'InputType' to the numeric code sent to the platform bridge.
inputTypeToInt :: InputType -> Int32
inputTypeToInt InputText      = 0
inputTypeToInt InputNumber    = 1
inputTypeToInt InputMultiline = 2
inputTypeToInt InputPassword  = 3

-- | Apply a 'FontConfig' to a rendered node if present.
applyFontConfig :: Int32 -> Maybe FontConfig -> IO ()
applyFontConfig nodeId (Just (FontConfig size weight family slant)) = do
  Bridge.setNumProp nodeId Bridge.PropFontSize size
  Bridge.setNumProp nodeId Bridge.PropFontStyle
    ((if weight == FontBold then 1 else 0) + (if family == FontMonospace then 2 else 0)
       + (if slant == FontItalic then 4 else 0))
applyFontConfig _nodeId Nothing = pure ()

-- | Apply a text color to a rendered node if present (the per-config
-- color, see 'tcTextColor').
applyTextColor :: Int32 -> Maybe Color -> IO ()
applyTextColor nodeId (Just color) =
  Bridge.setStrProp nodeId Bridge.PropColor (colorToHex color)
applyTextColor _nodeId Nothing = pure ()

-- | Map a 'ScaleType' to the numeric code sent to the platform bridge.
scaleTypeToDouble :: ScaleType -> Double
scaleTypeToDouble ScaleFit  = 0
scaleTypeToDouble ScaleFill = 1
scaleTypeToDouble ScaleNone = 2

-- | Map a 'TextAlignment' to the numeric code sent to the platform bridge.
textAlignToDouble :: TextAlignment -> Double
textAlignToDouble AlignStart  = 0
textAlignToDouble AlignCenter = 1
textAlignToDouble AlignEnd    = 2

-- | Map a 'SelfAlignment' to the numeric code sent to the platform bridge.
selfAlignToDouble :: SelfAlignment -> Double
selfAlignToDouble SelfStart   = 0
selfAlignToDouble SelfCenter  = 1
selfAlignToDouble SelfEnd     = 2
selfAlignToDouble SelfStretch = 3

-- | Apply 'WidgetStyle' overrides to a rendered node by calling
-- 'Bridge.setNumProp' / 'Bridge.setStrProp' for each 'Just' field.
applyStyle :: Int32 -> WidgetStyle -> IO ()
applyStyle nodeId style = do
  case wsPadding style of
    Just padding -> Bridge.setNumProp nodeId Bridge.PropPadding padding
    Nothing      -> pure ()
  -- After the padding, which sets all four sides.
  mapM_ (Bridge.setNumProp nodeId Bridge.PropPaddingY) (wsPaddingY style)
  case wsTextAlign style of
    Just alignment -> Bridge.setNumProp nodeId Bridge.PropGravity (textAlignToDouble alignment)
    Nothing        -> pure ()
  case wsBackgroundColor style of
    Just color -> Bridge.setStrProp nodeId Bridge.PropBgColor (colorToHex color)
    Nothing    -> pure ()
  case wsTranslateX style of
    Just tx -> Bridge.setNumProp nodeId Bridge.PropTranslateX tx
    Nothing -> pure ()
  case wsTranslateY style of
    Just ty -> Bridge.setNumProp nodeId Bridge.PropTranslateY ty
    Nothing -> pure ()
  case wsWidth style of
    Just width -> Bridge.setNumProp nodeId Bridge.PropWidth width
    Nothing    -> pure ()
  case wsTouchPassthrough style of
    Just enabled -> Bridge.setNumProp nodeId Bridge.PropTouchPassthrough
                      (if enabled then 1.0 else 0.0)
    Nothing      -> pure ()
  mapM_ (Bridge.setNumProp nodeId Bridge.PropHeight) (wsHeight style)
  mapM_ (Bridge.setNumProp nodeId Bridge.PropWeight) (wsWeight style)
  mapM_ (Bridge.setNumProp nodeId Bridge.PropAlignSelf . selfAlignToDouble)
    (wsAlignSelf style)
  mapM_ (Bridge.setNumProp nodeId Bridge.PropMargin) (wsMargin style)
  mapM_ (Bridge.setNumProp nodeId Bridge.PropMaxWidth) (wsMaxWidth style)
  mapM_ (Bridge.setNumProp nodeId Bridge.PropMaxLines . fromIntegral) (wsMaxLines style)
  mapM_ (Bridge.setNumProp nodeId Bridge.PropCornerRadius) (wsCornerRadius style)
  mapM_ (setCorners nodeId) (wsCorners style)
  mapM_ (Bridge.setNumProp nodeId Bridge.PropKeepAtEnd . boolToDouble) (wsKeepAtEnd style)
  where
    boolToDouble enabled = if enabled then 1.0 else 0.0

-- | Each corner's radius, or with NaN, 'wsCornerRadius' again.
setCorners :: Int32 -> Corners -> IO ()
setCorners nodeId (Corners topLeft topRight bottomRight bottomLeft) = do
  Bridge.setNumProp nodeId Bridge.PropCornerTopLeft topLeft
  Bridge.setNumProp nodeId Bridge.PropCornerTopRight topRight
  Bridge.setNumProp nodeId Bridge.PropCornerBottomRight bottomRight
  Bridge.setNumProp nodeId Bridge.PropCornerBottomLeft bottomLeft

-- | Put back what the old style set and the new one leaves alone, as a
-- node may be reused for another widget, like a lazy list's rows. Keeping
-- at the end and passing touches through stay as they are.
clearStyle :: Int32 -> WidgetStyle -> WidgetStyle -> IO ()
clearStyle nodeId old new = do
  cleared wsPadding $ Bridge.setNumProp nodeId Bridge.PropPadding 0
  cleared wsTextAlign $ Bridge.setNumProp nodeId Bridge.PropGravity (textAlignToDouble AlignStart)
  cleared wsBackgroundColor $ Bridge.setStrProp nodeId Bridge.PropBgColor (colorToHex transparent)
  cleared wsTranslateX $ Bridge.setNumProp nodeId Bridge.PropTranslateX 0
  cleared wsTranslateY $ Bridge.setNumProp nodeId Bridge.PropTranslateY 0
  -- Layout parameters the parent gives a child are kept where one is NaN.
  cleared wsWidth $ Bridge.setNumProp nodeId Bridge.PropWidth unset
  cleared wsHeight $ Bridge.setNumProp nodeId Bridge.PropHeight unset
  cleared wsWeight $ Bridge.setNumProp nodeId Bridge.PropWeight unset
  cleared wsAlignSelf $ Bridge.setNumProp nodeId Bridge.PropAlignSelf unset
  cleared wsMargin $ Bridge.setNumProp nodeId Bridge.PropMargin unset
  cleared wsMaxWidth $ Bridge.setNumProp nodeId Bridge.PropMaxWidth unlimited
  cleared wsMaxLines $ Bridge.setNumProp nodeId Bridge.PropMaxLines unlimited
  cleared wsCornerRadius $ Bridge.setNumProp nodeId Bridge.PropCornerRadius 0
  -- Any padding of the new style is set again after this.
  cleared wsPaddingY $ Bridge.setNumProp nodeId Bridge.PropPaddingY 0
  cleared wsCorners $ setCorners nodeId (Corners unset unset unset unset)
  where
    cleared :: (WidgetStyle -> Maybe a) -> IO () -> IO ()
    cleared field = when (isJust (field old) && isNothing (field new))
    unset = 0 / 0
    unlimited = fromIntegral (maxBound :: Int32)
    transparent = Color 0 0 0 0

-- ---------------------------------------------------------------------------
-- Creating rendered nodes from scratch
-- ---------------------------------------------------------------------------

-- | Create a container native node, recursively rendering each child
-- and attaching it via the bridge.  Used by Column, Row, and Stack which
-- share identical child-processing logic.
createContainerNode :: AnimationState -> Widget -> Bridge.NodeType
                    -> [LayoutItem] -> IO RenderedNode
createContainerNode animState widget nodeType layoutItems = do
  nodeId <- Bridge.createNode nodeType
  keyedChildren <- mapM (\(index, layoutItem) -> do
    let keyVal = resolveKeyAtIndex index layoutItem
    childNode <- createRenderedNode animState (liWidget layoutItem)
    Bridge.addChild nodeId (renderedNodeId childNode)
    pure (keyVal, childNode)
    ) (zip [0..] layoutItems)
  pure (RenderedContainer widget nodeId keyedChildren)

-- | Create a native node from a 'Widget', returning a 'RenderedNode'
-- snapshot. Used for fresh creation (no old node to diff against).
createRenderedNode :: AnimationState -> Widget -> IO RenderedNode
createRenderedNode _animState widget@(Text config) = do
  nodeId <- Bridge.createNode Bridge.NodeText
  Bridge.setStrProp nodeId Bridge.PropText (tcLabel config)
  applyFontConfig nodeId (tcFontConfig config)
  applyTextColor nodeId (tcTextColor config)
  pure (RenderedLeaf widget nodeId)
createRenderedNode _animState widget@(Button config) = do
  nodeId <- Bridge.createNode Bridge.NodeButton
  Bridge.setStrProp nodeId Bridge.PropText (bcLabel config)
  Bridge.setHandler nodeId Bridge.EventClick (actionId (bcAction config))
  applyFontConfig nodeId (bcFontConfig config)
  applyTextColor nodeId (bcTextColor config)
  pure (RenderedLeaf widget nodeId)
createRenderedNode _animState widget@(TextInput config) = do
  nodeId <- Bridge.createNode Bridge.NodeTextInput
  Bridge.setStrProp nodeId Bridge.PropText (tiValue config)
  Bridge.setStrProp nodeId Bridge.PropHint (tiHint config)
  Bridge.setNumProp nodeId Bridge.PropInputType (Int32.toDouble (inputTypeToInt (tiInputType config)))
  Bridge.setHandler nodeId Bridge.EventTextChange (onChangeId (tiOnChange config))
  applyFontConfig nodeId (tiFontConfig config)
  applyTextColor nodeId (tiTextColor config)
  when (tiAutoFocus config) $
    Bridge.setNumProp nodeId Bridge.PropAutoFocus 1.0
  pure (RenderedLeaf widget nodeId)
createRenderedNode animState widget@(Column settings) = do
  let nodeType = if lsScrollable settings
        then Bridge.NodeScrollView
        else Bridge.NodeColumn
  createContainerNode animState widget nodeType (lsWidgets settings)
createRenderedNode animState widget@(Row settings) = do
  let nodeType = if lsScrollable settings
        then Bridge.NodeHorizontalScrollView
        else Bridge.NodeRow
  createContainerNode animState widget nodeType (lsWidgets settings)
createRenderedNode animState widget@(Stack items) =
  createContainerNode animState widget Bridge.NodeStack items
createRenderedNode _animState widget@(LazyColumn items) = do
  nodeId <- Bridge.createNode Bridge.NodeLazyColumn
  rows <- LazyRows <$> newIORef (Seq.fromList items) <*> newIORef IntMap.empty
  setItemCount nodeId (length items)
  pure (RenderedLazy widget nodeId rows)
createRenderedNode _animState widget@(Image config) = do
  nodeId <- Bridge.createNode Bridge.NodeImage
  case icSource config of
    ImageResource (ResourceName name) -> Bridge.setStrProp nodeId Bridge.PropImageResource name
    ImageData bytes                   -> Bridge.setImageData nodeId bytes
    ImageFile path                    -> Bridge.setStrProp nodeId Bridge.PropImageFile (pack path)
    ImageStream key                   -> Bridge.setStrProp nodeId Bridge.PropImageStream key
  Bridge.setNumProp nodeId Bridge.PropScaleType (scaleTypeToDouble (icScaleType config))
  pure (RenderedLeaf widget nodeId)
createRenderedNode _animState widget@(WebView config) = do
  nodeId <- Bridge.createNode Bridge.NodeWebView
  Bridge.setStrProp nodeId Bridge.PropWebViewUrl (wvUrl config)
  case wvOnPageLoad config of
    Just action -> Bridge.setHandler nodeId Bridge.EventClick (actionId action)
    Nothing     -> pure ()
  pure (RenderedLeaf widget nodeId)
createRenderedNode _animState widget@(MapView config) = do
  nodeId <- Bridge.createNode Bridge.NodeMapView
  Bridge.setNumProp nodeId Bridge.PropMapLat (mvLatitude config)
  Bridge.setNumProp nodeId Bridge.PropMapLon (mvLongitude config)
  Bridge.setNumProp nodeId Bridge.PropMapZoom (mvZoom config)
  Bridge.setNumProp nodeId Bridge.PropMapShowUserLoc
    (if mvShowUserLocation config then 1.0 else 0.0)
  case mvOnRegionChange config of
    Just onChange -> Bridge.setHandler nodeId Bridge.EventTextChange
                      (onChangeId onChange)
    Nothing      -> pure ()
  pure (RenderedLeaf widget nodeId)
createRenderedNode animState widget@(Styled style child) = do
  childNode <- createRenderedNode animState child
  applyStyle (renderedNodeId childNode) style
  pure (RenderedStyled widget style childNode)
createRenderedNode animState widget@(Tappable action child) = do
  childNode <- createRenderedNode animState child
  Bridge.setHandler (renderedNodeId childNode) Bridge.EventClick (actionId action)
  pure (RenderedTappable widget childNode)
createRenderedNode animState widget@(Scrolled onChange _ child) = do
  childNode <- createRenderedNode animState child
  Bridge.setHandler (renderedNodeId childNode) Bridge.EventScrolled (onScrollId onChange)
  pure (RenderedTappable widget childNode)
createRenderedNode animState widget@(LongPressable action child) = do
  childNode <- createRenderedNode animState child
  Bridge.setHandler (renderedNodeId childNode) Bridge.EventLongPress (actionId action)
  pure (RenderedTappable widget childNode)
createRenderedNode animState (Animated config child) = do
  let normalized = normalizeAnimated config child
  case normalized of
    -- normalizeAnimated distributed into a container — render the container directly
    -- (each child is now individually wrapped in Animated).
    Column _     -> createRenderedNode animState normalized
    Row _        -> createRenderedNode animState normalized
    Stack _      -> createRenderedNode animState normalized
    -- Everything else (Styled, leaves): wrap in RenderedAnimated for tween interpolation.
    -- Apply first keyframe's style, register tween if >1 keyframe.
    _            -> do
      let finalWidget = Animated config normalized
          sortedKeyframes = sortBy (comparing kfAt) (anKeyframes config)
      childNode <- createRenderedNode animState normalized
      -- Apply the first keyframe's style as the initial visual state
      case sortedKeyframes of
        (firstKf : _) -> applyStyle (renderedNodeId childNode) (kfStyle firstKf)
        []            -> pure ()
      -- Register tween if there are at least 2 keyframes
      case sortedKeyframes of
        (_ : _ : _) ->
          registerTween animState (renderedNodeId childNode)
            sortedKeyframes (anDuration config)
        _ -> pure ()
      pure (RenderedAnimated finalWidget childNode)

-- ---------------------------------------------------------------------------
-- Destroying rendered subtrees
-- ---------------------------------------------------------------------------

-- | Recursively destroy all native nodes in a rendered subtree.
destroyRenderedSubtree :: RenderedNode -> IO ()
destroyRenderedSubtree (RenderedLeaf _ nodeId) =
  Bridge.destroyNode nodeId
destroyRenderedSubtree (RenderedContainer _ nodeId keyedChildren) = do
  mapM_ (destroyRenderedSubtree . snd) keyedChildren
  Bridge.destroyNode nodeId
destroyRenderedSubtree (RenderedTappable _ child) =
  destroyRenderedSubtree child
destroyRenderedSubtree (RenderedStyled _ _ child) =
  destroyRenderedSubtree child
destroyRenderedSubtree (RenderedAnimated _ child) =
  destroyRenderedSubtree child
destroyRenderedSubtree (RenderedLazy _ nodeId rows) = do
  shown <- readIORef (lrRows rows)
  mapM_ (\(rowId, item) -> do
    destroyRenderedSubtree item
    mapM_ Bridge.destroyNode (Int.toInt32 rowId)
    ) (IntMap.toList shown)
  Bridge.destroyNode nodeId

-- ---------------------------------------------------------------------------
-- Incremental diff algorithm
-- ---------------------------------------------------------------------------

-- | Check whether two widgets use the same constructor (node type).
-- Does not compare contents — just the outermost constructor tag.
sameNodeType :: Widget -> Widget -> Bool
sameNodeType (Text _)        (Text _)        = True
sameNodeType (Button _)      (Button _)      = True
sameNodeType (TextInput _)   (TextInput _)   = True
sameNodeType (Column a)      (Column b)      = lsScrollable a == lsScrollable b
sameNodeType (Row a)         (Row b)         = lsScrollable a == lsScrollable b
sameNodeType (Stack _)       (Stack _)       = True
sameNodeType (Image _)       (Image _)       = True
sameNodeType (WebView _)     (WebView _)     = True
sameNodeType (MapView _)     (MapView _)     = True
sameNodeType (Styled _ _)    (Styled _ _)    = True
sameNodeType (Tappable _ _)  (Tappable _ _)  = True
sameNodeType (LongPressable _ _) (LongPressable _ _) = True
sameNodeType (Scrolled _ _ _) (Scrolled _ _ _) = True
sameNodeType (Animated _ _)  (Animated _ _)  = True
sameNodeType (LazyColumn _)  (LazyColumn _)  = True
sameNodeType _               _               = False

-- | Diff the old rendered tree against a new 'Widget' and produce
-- an updated 'RenderedNode', emitting only the necessary bridge calls.
--
-- Cases:
-- 1. No old node -> create from scratch.
-- 2. @newWidget == renderedWidget oldNode@ -> reuse native node entirely (zero work).
-- 3. Same container type, children differ -> keep container, diff children.
-- 4. Same Styled, diff child recursively, re-apply style if changed.
-- 5. Same leaf type but properties differ -> destroy old, create new.
-- 6. Different node type -> destroy old subtree, create new.
diffRenderNode :: AnimationState -> Maybe RenderedNode -> Widget -> IO RenderedNode
-- Case 1: No previous node — create from scratch.
diffRenderNode animState Nothing newWidget =
  createRenderedNode animState newWidget

-- Case 2: Exact match — reuse native node entirely.
diffRenderNode _animState (Just oldNode) newWidget
  | newWidget == renderedWidget oldNode =
    pure oldNode

-- Case: Animated wrapping a container — normalize (distribute to children) and recurse.
diffRenderNode animState maybeOld (Animated config child@(Column _)) =
  diffRenderNode animState maybeOld (normalizeAnimated config child)
diffRenderNode animState maybeOld (Animated config child@(Row _)) =
  diffRenderNode animState maybeOld (normalizeAnimated config child)
diffRenderNode animState maybeOld (Animated config child@(Stack _)) =
  diffRenderNode animState maybeOld (normalizeAnimated config child)
-- Case: Nested Animated — inner config wins.
diffRenderNode animState maybeOld (Animated _outerConfig child@(Animated _ _)) =
  diffRenderNode animState maybeOld child

-- Case: Both are Animated (leaf) — diff the child, possibly registering a tween.
diffRenderNode animState (Just (RenderedAnimated _ oldChildNode)) (Animated newConfig newChild) = do
  let oldChildWidget = renderedWidget oldChildNode
      sortedKeyframes = sortBy (comparing kfAt) (anKeyframes newConfig)
  if sameNodeType oldChildWidget newChild
    then do
      -- Same child node type: keep native node, register tween if properties differ
      if oldChildWidget /= newChild
        then case sortedKeyframes of
               (_ : _ : _) ->
                 registerTween animState (renderedNodeId oldChildNode)
                   sortedKeyframes (anDuration newConfig)
               _ -> pure ()
        else pure ()
      -- Update the RenderedAnimated to reflect the new target
      let updatedChildNode = updateRenderedTarget newChild oldChildNode
      pure (RenderedAnimated (Animated newConfig newChild) updatedChildNode)
    else do
      -- Different child type: can't animate, destroy+create
      destroyRenderedSubtree oldChildNode
      newChildNode <- createRenderedNode animState newChild
      pure (RenderedAnimated (Animated newConfig newChild) newChildNode)

-- Case 4: Both are Styled — diff child recursively.
diffRenderNode animState (Just (RenderedStyled _ oldStyle oldChild)) (Styled newStyle newChild) = do
  diffedChild <- diffRenderNode animState (Just oldChild) newChild
  let nodeChanged = renderedNodeId diffedChild /= renderedNodeId oldChild
  if newStyle /= oldStyle || nodeChanged
    then do
      unless nodeChanged $ clearStyle (renderedNodeId diffedChild) oldStyle newStyle
      applyStyle (renderedNodeId diffedChild) newStyle
    else pure ()
  pure (RenderedStyled (Styled newStyle newChild) newStyle diffedChild)

-- Both are Tappable: diff the child, and point its handler at the new
-- action if that or the child's node changed.
diffRenderNode animState (Just (RenderedTappable (Tappable oldAction _) oldChild)) (Tappable newAction newChild) = do
  diffedChild <- diffRenderNode animState (Just oldChild) newChild
  if newAction /= oldAction || renderedNodeId diffedChild /= renderedNodeId oldChild
    then Bridge.setHandler (renderedNodeId diffedChild) Bridge.EventClick (actionId newAction)
    else pure ()
  pure (RenderedTappable (Tappable newAction newChild) diffedChild)

-- Both are Scrolled: the same, and to its end when its number changed.
diffRenderNode animState (Just (RenderedTappable (Scrolled oldChange oldJump _) oldChild)) (Scrolled newChange newJump newChild) = do
  diffedChild <- diffRenderNode animState (Just oldChild) newChild
  let node = renderedNodeId diffedChild
  if newChange /= oldChange || node /= renderedNodeId oldChild
    then Bridge.setHandler node Bridge.EventScrolled (onScrollId newChange)
    else pure ()
  if newJump /= oldJump then Bridge.setNumProp node Bridge.PropScrollToEnd (fromIntegral newJump) else pure ()
  pure (RenderedTappable (Scrolled newChange newJump newChild) diffedChild)

-- Both are LongPressable: the same, for holding.
diffRenderNode animState (Just (RenderedTappable (LongPressable oldAction _) oldChild)) (LongPressable newAction newChild) = do
  diffedChild <- diffRenderNode animState (Just oldChild) newChild
  if newAction /= oldAction || renderedNodeId diffedChild /= renderedNodeId oldChild
    then Bridge.setHandler (renderedNodeId diffedChild) Bridge.EventLongPress (actionId newAction)
    else pure ()
  pure (RenderedTappable (LongPressable newAction newChild) diffedChild)

-- Case 3: Same container type, children may differ — keep container, diff children.
diffRenderNode animState (Just oldNode@(RenderedContainer _ containerNodeId oldKeyedChildren)) newWidget
  | sameNodeType (renderedWidget oldNode) newWidget =
    case newWidget of
      Column settings        -> diffContainer animState containerNodeId oldKeyedChildren (lsWidgets settings) newWidget
      Row settings           -> diffContainer animState containerNodeId oldKeyedChildren (lsWidgets settings) newWidget
      Stack newItems         -> diffContainer animState containerNodeId oldKeyedChildren newItems newWidget
      -- Non-container but same type at container level shouldn't happen,
      -- but fall through to destroy+create for safety.
      _ -> replaceNode animState oldNode newWidget

-- Both are LazyColumn: keep the list and its rows, and have the platform
-- show the items again, which renders each row's new item into it.
diffRenderNode _animState (Just (RenderedLazy _ nodeId rows)) newWidget@(LazyColumn items) = do
  writeIORef (lrItems rows) (Seq.fromList items)
  setItemCount nodeId (length items)
  pure (RenderedLazy newWidget nodeId rows)

-- Case: Text in-place update — keep native node, only update changed
-- properties.  Avoids destroying and recreating sibling nodes in a
-- Column, which would detach EditText from the view hierarchy and
-- disconnect the IME (see TextInput case below).
diffRenderNode _animState (Just (RenderedLeaf (Text oldConfig) nodeId)) newWidget@(Text newConfig) = do
  if tcLabel oldConfig /= tcLabel newConfig
    then Bridge.setStrProp nodeId Bridge.PropText (tcLabel newConfig)
    else pure ()
  if tcFontConfig oldConfig /= tcFontConfig newConfig
    then applyFontConfig nodeId (tcFontConfig newConfig)
    else pure ()
  if tcTextColor oldConfig /= tcTextColor newConfig
    then applyTextColor nodeId (tcTextColor newConfig)
    else pure ()
  pure (RenderedLeaf newWidget nodeId)

-- Case: Button in-place update — keep native node, only update changed
-- properties.
diffRenderNode _animState (Just (RenderedLeaf (Button oldConfig) nodeId)) newWidget@(Button newConfig) = do
  if bcLabel oldConfig /= bcLabel newConfig
    then Bridge.setStrProp nodeId Bridge.PropText (bcLabel newConfig)
    else pure ()
  if actionId (bcAction oldConfig) /= actionId (bcAction newConfig)
    then Bridge.setHandler nodeId Bridge.EventClick (actionId (bcAction newConfig))
    else pure ()
  if bcFontConfig oldConfig /= bcFontConfig newConfig
    then applyFontConfig nodeId (bcFontConfig newConfig)
    else pure ()
  if bcTextColor oldConfig /= bcTextColor newConfig
    then applyTextColor nodeId (bcTextColor newConfig)
    else pure ()
  pure (RenderedLeaf newWidget nodeId)

-- Case: TextInput in-place update — keep native node to preserve
-- cursor position and focus. Only sends bridge calls for properties
-- that actually changed.
diffRenderNode _animState (Just (RenderedLeaf (TextInput oldConfig) nodeId)) newWidget@(TextInput newConfig) = do
  if tiValue oldConfig /= tiValue newConfig
    then Bridge.setStrProp nodeId Bridge.PropText (tiValue newConfig)
    else pure ()
  if tiHint oldConfig /= tiHint newConfig
    then Bridge.setStrProp nodeId Bridge.PropHint (tiHint newConfig)
    else pure ()
  if tiInputType oldConfig /= tiInputType newConfig
    then Bridge.setNumProp nodeId Bridge.PropInputType
           (Int32.toDouble (inputTypeToInt (tiInputType newConfig)))
    else pure ()
  if onChangeId (tiOnChange oldConfig) /= onChangeId (tiOnChange newConfig)
    then Bridge.setHandler nodeId Bridge.EventTextChange
           (onChangeId (tiOnChange newConfig))
    else pure ()
  if tiFontConfig oldConfig /= tiFontConfig newConfig
    then applyFontConfig nodeId (tiFontConfig newConfig)
    else pure ()
  if tiTextColor oldConfig /= tiTextColor newConfig
    then applyTextColor nodeId (tiTextColor newConfig)
    else pure ()
  pure (RenderedLeaf newWidget nodeId)

-- Case 5/6: Same leaf type with different properties, or completely different
-- node types — destroy old and create new.
diffRenderNode animState (Just oldNode) newWidget =
  replaceNode animState oldNode newWidget

-- | Diff container children by key.  Matches new children against old
-- by resolved 'WidgetKey', so inserting a child at position 0 no longer
-- causes all subsequent children to mismatch.
--
-- Native children are removed and added only where the order changed:
-- the ones gone are removed, the ones that stay in front are left
-- alone, and those after them are added again in the new order.  A
-- child taken out of the view hierarchy loses its state, such as an
-- EditText's focus and IME connection, so appending or removing
-- children leaves the others attached.
diffContainer :: AnimationState -> Int32 -> [(Int, RenderedNode)] -> [LayoutItem]
              -> Widget -> IO RenderedNode
diffContainer animState containerNodeId oldKeyedChildren newLayoutItems newWidget = do
  -- Build IntMap from old children's stored keys (first occurrence wins on dup)
  let oldKeyMap = IntMap.fromList oldKeyedChildren
  -- Match new children against old by key (index-based for unkeyed items)
  (diffedKeyedChildren, usedKeySet) <- matchNewChildren animState oldKeyMap newLayoutItems
  let unusedOld = IntMap.elems (IntMap.withoutKeys oldKeyMap usedKeySet)
      unusedIds = map renderedNodeId unusedOld
      -- What stays attached, in its native order, once the unused are gone.
      keptIds = filter (`notElem` unusedIds) (map (renderedNodeId . snd) oldKeyedChildren)
      (detached, added) = reattachments keptIds (map (renderedNodeId . snd) diffedKeyedChildren)
  mapM_ (\oldChild -> do
    Bridge.removeChild containerNodeId (renderedNodeId oldChild)
    destroyRenderedSubtree oldChild
    ) unusedOld
  mapM_ (Bridge.removeChild containerNodeId) detached
  mapM_ (Bridge.addChild containerNodeId) added
  pure (RenderedContainer newWidget containerNodeId diffedKeyedChildren)

-- | Which of a container's native children to take out and which to add,
-- in order, to go from the attached ones to the new ones: all after the
-- ones both start with.
reattachments :: [Int32] -> [Int32] -> ([Int32], [Int32])
reattachments attached new = (drop inFront attached, drop inFront new)
  where
    inFront = length (takeWhile id (zipWith (==) attached new))

-- | Match new children against old children by resolved key.
-- Children without explicit keys use their list index as the key,
-- so they match by position.  Children with explicit keys match by key
-- regardless of position.
matchNewChildren :: AnimationState -> IntMap RenderedNode
                 -> [LayoutItem] -> IO ([(Int, RenderedNode)], IntSet)
matchNewChildren animState oldKeyMap newItems =
    go IntSet.empty (zip [0..] newItems)
  where
    go :: IntSet -> [(Int, LayoutItem)]
       -> IO ([(Int, RenderedNode)], IntSet)
    go usedKeys [] = pure ([], usedKeys)
    go usedKeys ((index, layoutItem) : rest) = do
      let keyVal = resolveKeyAtIndex index layoutItem
          newChild = liWidget layoutItem
          maybeOld = if IntSet.member keyVal usedKeys
                     then Nothing
                     else IntMap.lookup keyVal oldKeyMap
      diffedChild <- case maybeOld of
        Just oldChild ->
          if sameNodeType (renderedWidget oldChild) newChild
            then diffRenderNode animState (Just oldChild) newChild
            else do
              destroyRenderedSubtree oldChild
              createRenderedNode animState newChild
        Nothing ->
          createRenderedNode animState newChild
      let usedKeys' = case maybeOld of
            Just _  -> IntSet.insert keyVal usedKeys
            Nothing -> usedKeys
      (restNodes, finalUsed) <- go usedKeys' rest
      pure ((keyVal, diffedChild) : restNodes, finalUsed)

-- | Destroy an old node and create a fresh replacement.
replaceNode :: AnimationState -> RenderedNode -> Widget -> IO RenderedNode
replaceNode animState oldNode newWidget = do
  destroyRenderedSubtree oldNode
  createRenderedNode animState newWidget

-- | Render a 'LazyColumn''s item into one of its rows, as the platform
-- asks while it scrolls: into the row with the given node ID, or a new
-- one for 0.  Gives the row's node ID, or 0 if there is no such list or
-- item, as after the platform dropped the views.
bindLazyRow :: RenderState -> Int32 -> Int32 -> Int -> IO Int32
bindLazyRow rs listId rowId position = do
  tree <- readIORef (rsRenderedTree rs)
  case tree >>= findLazy listId of
    Nothing -> pure 0
    Just rows -> do
      items <- readIORef (lrItems rows)
      case Seq.lookup position items of
        Nothing -> pure 0
        Just item -> do
          row <- if rowId == 0 then Bridge.createNode Bridge.NodeColumn else pure rowId
          shown <- readIORef (lrRows rows)
          let old = IntMap.lookup (Int32.toInt row) shown
          new <- diffRenderNode (rsAnimationState rs) old (liWidget item)
          when (fmap renderedNodeId old /= Just (renderedNodeId new)) $
            Bridge.addChild row (renderedNodeId new)
          writeIORef (lrRows rows) (IntMap.insert (Int32.toInt row) new shown)
          pure row

-- | The key of a 'LazyColumn''s item, for the platform to keep it on
-- screen when items before it change: its own, else its position.
lazyItemKey :: RenderState -> Int32 -> Int -> IO Int
lazyItemKey rs listId position = do
  tree <- readIORef (rsRenderedTree rs)
  items <- maybe (pure Seq.empty) (readIORef . lrItems) (tree >>= findLazy listId)
  pure (maybe position (resolveKeyAtIndex position) (Seq.lookup position items))

setItemCount :: Int32 -> Int -> IO ()
setItemCount nodeId count =
  mapM_ (Bridge.setNumProp nodeId Bridge.PropItemCount . Int32.toDouble) (Int.toInt32 count)

-- | The rows of the 'LazyColumn' with this node ID, outside any other
-- list's items.
findLazy :: Int32 -> RenderedNode -> Maybe LazyRows
findLazy listId = go
  where
    go (RenderedLazy _ nodeId rows)
      | nodeId == listId = Just rows
      | otherwise = Nothing
    go (RenderedLeaf _ _) = Nothing
    go (RenderedContainer _ _ children) = asum (map (go . snd) children)
    go (RenderedStyled _ _ child) = go child
    go (RenderedAnimated _ child) = go child
    go (RenderedTappable _ child) = go child

-- ---------------------------------------------------------------------------
-- Top-level render entry point
-- ---------------------------------------------------------------------------

-- | Forget the rendered tree and its tweens, after the platform dropped
-- their native views.  The next render creates them all again.
resetRender :: RenderState -> IO ()
resetRender rs = do
  writeIORef (rsRenderedTree rs) Nothing
  writeIORef (ansTweens (rsAnimationState rs)) IntMap.empty
  writeIORef (ansLoopActive (rsAnimationState rs)) False

-- | Incremental render: diffs the new widget tree against the previously
-- rendered tree and emits only the necessary bridge operations.
--
-- On the first call (no previous tree), performs a full creation.
-- On subsequent calls, reuses unchanged native nodes.
renderWidget :: RenderState -> Widget -> IO ()
renderWidget rs widget = do
  oldTree <- readIORef (rsRenderedTree rs)
  newTree <- diffRenderNode (rsAnimationState rs) oldTree widget
  -- Set root if this is the first render or the root node changed.
  case oldTree of
    Nothing -> Bridge.setRoot (renderedNodeId newTree)
    Just old
      | renderedNodeId old /= renderedNodeId newTree ->
          Bridge.setRoot (renderedNodeId newTree)
      | otherwise -> pure ()
  writeIORef (rsRenderedTree rs) (Just newTree)

-- ---------------------------------------------------------------------------
-- Event dispatch
-- ---------------------------------------------------------------------------

-- | Dispatch a native click event to the registered Haskell callback.
-- Logs an error to stderr if the callbackId is not found.
dispatchEvent :: RenderState -> Int32 -> IO ()
dispatchEvent rs callbackId = do
  maybeAction <- lookupAction (rsActionState rs) callbackId
  case maybeAction of
    Just action -> action
    Nothing     -> hPutStrLn stderr $
      "dispatchEvent: unknown callback ID " ++ show callbackId

-- | Dispatch a native text-change event to the registered Haskell callback.
-- The caller ('Hatter.haskellOnUITextChange') triggers a re-render
-- after dispatch; the diff algorithm updates TextInput nodes in-place
-- so the native widget is preserved (no cursor reset or flicker).
-- Logs an error to stderr if the callbackId is not found.
dispatchTextEvent :: RenderState -> Int32 -> Text -> IO ()
dispatchTextEvent rs callbackId newText = do
  maybeAction <- lookupTextAction (rsActionState rs) callbackId
  case maybeAction of
    Just action -> action newText
    Nothing     -> hPutStrLn stderr $
      "dispatchTextEvent: unknown callback ID " ++ show callbackId

-- | Dispatch where a list is, by the platform's number for it.
dispatchScrollEvent :: RenderState -> Int32 -> Int -> IO ()
dispatchScrollEvent rs callbackId position = do
  maybeAction <- lookupScrollAction (rsActionState rs) callbackId
  case (maybeAction, [p | p <- [minBound .. maxBound], fromEnum p == position]) of
    (Just action, p : _) -> action p
    (Just _, [])         -> hPutStrLn stderr $
      "dispatchScrollEvent: unknown position " ++ show position
    (Nothing, _)         -> hPutStrLn stderr $
      "dispatchScrollEvent: unknown callback ID " ++ show callbackId
