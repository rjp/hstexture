module Texture.UI where

import Control.Monad
import Control.Monad.State
import Control.Monad.Reader
import Control.Concurrent.MVar
import Data.Array.IArray

import Graphics.UI.SDL
import Graphics.UI.SDL.Image
import qualified Graphics.UI.SDL.Framerate as FR
import qualified Graphics.UI.SDL.Primitives as SDLP
import qualified Graphics.UI.SDL.TTF.General as TTFG
import Graphics.UI.SDL.TTF.Management
import Graphics.UI.SDL.TTF.Render
import Graphics.UI.SDL.TTF.Types
import Data.Maybe (listToMaybe, fromMaybe, fromJust, isJust, catMaybes)
import GHC.Int (Int16)
import qualified Texture.Types as T
import Data.List (intercalate, tails, nub)
import Data.Colour
import Data.Colour.Names
import Data.Colour.SRGB
import Data.Colour.RGBSpace.HSV (hsv)
import qualified GHC.Word 
import Data.Bits
import Data.Ratio
import Tempo
import Debug.Trace (trace)
import Data.Fixed (mod')

import Texture.Utils
import Texture.Interp (start, interpretPat, Job (OscJob, ColourJob))
import Stream (OscPattern)
import Dirt
import Pattern
import qualified Time

screenWidth  = 800
screenHeight = 600
screenBpp    = 32

xDivider = 0.75

data WordStatus = Active
                | Tentative
                | Typing
                | MenuItem
                deriving (Show, Eq)

data Word = Word {ident :: Int,
                  token :: String,
                  location :: (Float, Float),
                  size :: (Float, Float),
                  mousePos :: Maybe (Float, Float),
                  status :: WordStatus,
                  pat :: Maybe (Pattern (Colour Double))
                 }

instance Eq Word where
  (Word {ident = a}) == (Word {ident = b}) = a == b

data Scene = Scene {source :: [Word],
                    parsed :: [T.Datum],
                    mouseXY :: (Float, Float),
                    cursor :: (Float, Float)
                   }

getTyping :: [Word] -> Maybe Word
getTyping [] = Nothing
getTyping (x@(Word {status = Typing}):_) = Just x
getTyping (_:xs) = getTyping xs

makeTyping :: [Word] -> (Float, Float) -> Word
makeTyping ws loc = Word (nextIdent ws) "" loc (0,0) Nothing Typing Nothing

bottomRight :: Word -> (Float, Float)
bottomRight (Word {location = (x,y), size = (w,h)}) = (x+w, y+h)

bottomLeft :: Word -> (Float, Float)
bottomLeft (Word {location = (x,y), size = (w,h)}) = (x, y+h)

topRight :: Word -> (Float, Float)
topRight (Word {location = (x,y), size = (w,h)}) = (x+w, y)

parseScene :: Scene -> Scene
parseScene s = 
  s {parsed = (T.build $ map wordToDatum (filterActive $ source s))}

evalScene :: Scene -> AppEnv (Scene)
evalScene scene = 
  do let s = parseScene $ withSource scene clearMouseOffset
         code = T.walkTreesWhere (T.isOscPattern . T.applied_as) (parsed s)
     liftIO $ mapM_ (\d -> putStrLn $ T.token d ++ ": " ++ (show $ T.applied_as d)) (parsed s)
     if (null code) 
       then return s
       else do let code' = "stack [" ++ (intercalate ", " code) ++ "]"
               i <- input `liftM` ask
               liftIO $ putStrLn $ "sending '" ++ code' ++ "'"
               liftIO $ putMVar i (OscJob code')
               s' <- interpretPats s
               return s'

nextIdent :: [Word] -> Int
nextIdent ws = head $ filter (\i -> null $ filter ((== i) . ident) ws) [0 ..]

wordToDatum :: Word -> T.Datum
wordToDatum w = T.Datum {T.ident = ident w,
                         T.token = token w,
                         T.location = location w,
                         T.parentId = Nothing,
                         T.childIds = [],
                         T.sig  = s,
                         T.applied_as = s,
                         T.applied_location = location w
                        }
  where s = T.stringToSig (token w)

toScreen :: (Float, Float) -> (Int, Int)
toScreen (x, y) = (floor (x * (fromIntegral screenWidth)),
                   floor (y * (fromIntegral screenHeight))
                  )

toScreen16 :: (Float, Float) -> (Int16, Int16)
toScreen16 (x, y) = (fromIntegral $ floor (x * (fromIntegral screenWidth)),
                     fromIntegral $ floor (y * (fromIntegral screenHeight))
                    )

fromScreen :: (Int, Int) -> (Float, Float)
fromScreen (x, y) = ((fromIntegral x) / (fromIntegral screenWidth),
                     (fromIntegral y) / (fromIntegral screenHeight)
                    )

withSource :: Scene -> ([Word] -> [Word]) -> Scene
withSource s f = s {source = f $ source s}

withActive :: Scene -> ([Word] -> [Word]) -> Scene
withActive s f = withSource s (f . filterActive)

filterActive :: [Word] -> [Word]
filterActive = (filter ((== Active) . status))

clearMouseOffset :: [Word] -> [Word]
clearMouseOffset = (map clearTentative) . (map f) . (filter filtF)
  where f i = i {mousePos = Nothing}
        filtF i@(Word {status = Tentative, location = (x,_), size = (w,_)}) 
          = (x + w) <= xDivider
        filtF _ = True
        clearTentative i@(Word {status = Tentative}) = i {status = Active}
        clearTentative i = i

moveWord :: Scene -> (Float, Float) -> AppEnv Scene
moveWord s (x,y) | w == Nothing = return s
                 | otherwise = do ws <- moveWord' (source s) (x,y) (fromJust w)
                                  return $ parseScene $ s {source = ws}
  where w = moving $ source s

moveWord' :: [Word] -> (Float, Float) -> Word -> AppEnv [Word]
moveWord' ws loc wd@(Word {status = MenuItem}) = moveWord' ws' loc newWord
  where newWord = wd {status = Tentative, ident = nextIdent ws}
        ws' = newWord:(clearMouseOffset ws)

moveWord' ws (x,y) wd =
  return $ fromMaybe ws $ 
       do (xOffset, yOffset) <- mousePos wd
          let (w,h) = size wd
              x' | status wd == Tentative = (x-xOffset)
                 | otherwise = max 0 $ min (xDivider - w) (x - xOffset)
              y' = max 0 $ min (1 - h) $ y - yOffset
          return $ updateWord ws $ wd {location = (x',y')}

inWord :: (Float, Float) -> Word -> Bool
inWord (px,py) Word {size = (w,h), location = (x,y)} =
  and [px >= x, py >= y, px < x+w, py < y+h]

instructionAt :: [Word] -> (Float, Float) -> Maybe Word
instructionAt ws location = listToMaybe $ filter (inWord location) ws

moving :: [Word] -> Maybe Word
moving = listToMaybe . (filter (isJust . mousePos))

updateAddWord :: [Word] -> Word -> [Word]
updateAddWord [] w = [w]
updateAddWord (x:xs) i | ident x == ident i = (i:xs)
                       | otherwise = x:(updateAddWord xs i)

updateWord :: [Word] -> Word -> [Word]
updateWord [] _ = []
updateWord (x:xs) i | ident x == ident i = (i:xs)
                    | otherwise = x:(updateWord xs i)

removeWord :: [Word] -> Word -> [Word]
removeWord ws w = filter (w /=) ws

wordByIdent :: [Word] -> Int -> Word
wordByIdent ds i = head $ filter (\d -> ident d == i) ds

isInside :: Integral a => Rect -> a -> a -> Bool
isInside (Rect rx ry rw rh) x y = (x' > rx) && (x' < rx + rw) && (y' > ry) && (y' < ry + rh)
 where (x', y') = (fromIntegral x, fromIntegral y)

setMouseOffset :: (Float, Float) -> Word -> Word
setMouseOffset (x,y) w = w {mousePos = Just (x',y')}
  where x' = x - (fst $ location w)
        y' = y - (snd $ location w)

handleEvent :: Scene -> Event -> AppEnv (Scene)
handleEvent s (MouseMotion x y _ _) = 
  do s' <- moveWord s xy
     return $ parseScene (s' {mouseXY = xy})
  where xy = (fromScreen (fromIntegral x, fromIntegral y))

--return $ parseScene $ source $ withSource scene (\ws -> moveWord ws (fromScreen (fromIntegral x, fromIntegral y)))

handleEvent scene (MouseButtonDown x y ButtonLeft) = 
  finishTyping $ updateScene $ instructionAt (source scene) xy 
  where updateScene Nothing = scene {cursor = xy}
        updateScene (Just w) = 
          scene {source = updateWord (source scene) (setMouseOffset xy w)}
        xy = fromScreen (fromIntegral x, fromIntegral y)

handleEvent scene (MouseButtonUp x y ButtonLeft) = evalScene scene

handleEvent scene (KeyDown k) =
  handleKey scene (getKeyName $ symKey k) (symModifiers k)

handleEvent scene _ = return scene

typing :: Scene -> Word
typing scene = 
  fromMaybe (makeTyping (source scene) (cursor scene)) 
            (getTyping (source scene))

finishTyping :: Scene -> AppEnv (Scene)
finishTyping scene | w == Nothing = return scene
                   | otherwise = evalScene $ parseScene $ withSource scene (\ws -> updateWord ws ((fromJust w) {status = Active}))
  where w = getTyping (source scene)

updateSize :: Int -> Scene -> AppEnv Scene
updateSize i scene = 
  do ft <- font `liftM` ask
     w' <- liftIO (setSize w ft)
     return $ updateCursor w' $ withSource scene (\ws -> updateWord ws w')
  where w = wordByIdent (source scene) i
        updateCursor w s = s {cursor = topRight w}

handleKey :: Scene -> String -> [Modifier] -> AppEnv Scene
handleKey scene (c:[]) mods = 
  do let w = (typing scene) 
         w' = w {token = (token w) ++ [c]}
     updateSize (ident w') $ withSource scene (\ws -> updateAddWord ws w')

handleKey scene "space" mods = 
  finishTyping $ scene {cursor = addBlank $ topRight (typing scene)}
  where addBlank (x,y) = (x+blankWidth,y)

handleKey scene "return" mods = 
  finishTyping $ scene {cursor = bottomLeft (typing scene)}

handleKey scene "backspace" mods = 
  deleteChar $ getTyping (source scene)
  where deleteChar (Just w) | length (token w) > 1 = updateSize (ident w) $ withSource scene (\ws -> updateWord ws (w {token = Prelude.init (token w)}))
                            | otherwise = return $ withSource scene (\ws -> removeWord ws w)
        deleteChar Nothing = return $ scene {cursor = removeBlank $ cursor scene}
        removeBlank (x,y) = (x-blankWidth,y)        

handleKey scene "delete" mods = handleKey scene "backspace" mods
        

handleKey scene s _ = 
  do liftIO $ putStrLn s
     return scene

resetPats :: [Word] -> [Word]
resetPats = map (\w -> w {pat = Nothing})

interpretPats :: Scene -> AppEnv Scene
interpretPats s = do ps <- pats
                     metaPs <- metaPats
                     let ws = foldr (Prelude.flip updateWord) (resetPats $ source s) (ps ++ metaPs)
                     return $ s {source = ws}
  where isPatterned x = T.hasParent x && T.isPattern (T.appliedConcreteType x)
        patterned = (filter isPatterned $ parsed s) :: [T.Datum]
        simpleJob d = runJob (d, (fromJust' $ T.patternType $ T.appliedConcreteType d), T.walkTree (parsed s) d)
        runJob (d, t, code) = 
          do let job = ColourJob t code
             i <- input `liftM` ask
             o <- colourOutput `liftM` ask
             liftIO $ putMVar i job
             p <- liftIO $ takeMVar o
             let w = wordByIdent (source s) (T.ident d)
             return $ w {pat = Just p}
        pats = mapM simpleJob patterned
        metas :: [(T.Datum, T.Type, String)]
        metas = catMaybes $ map (T.guessTransform (parsed s)) (parsed s)
        metaPats = mapM runJob metas

data AppConfig = AppConfig {
  screen       :: Surface,
  font         :: Font,
  input        :: MVar Job,
  oscOutput    :: MVar OscPattern,
  colourOutput :: MVar (Pattern (Colour Double)),
  tempoMV      :: MVar (Tempo),
  fr           :: FR.FPSManager
}

type AppState = StateT Scene IO
type AppEnv = ReaderT AppConfig AppState

applySurface :: Int -> Int -> Surface -> Surface -> Maybe Rect -> IO Bool
applySurface x y src dst clip = blitSurface src clip dst offset
 where offset = Just Rect { rectX = x, rectY = y, rectW = 0, rectH = 0 }

initEnv :: IO AppConfig
initEnv = do    
    screen <- setVideoMode screenWidth screenHeight screenBpp [SWSurface]
    font <- openFont "inconsolata.ttf" 18
    setCaption "Texture" []
    oscO <- dirtstart "texture"
    colourO <- newEmptyMVar
    i <- start oscO colourO
    tempoMV <- tempoMVar
    fps <- FR.new
    FR.set fps 20
    FR.init fps
    return $ AppConfig screen font i oscO colourO tempoMV fps

blankWidth = 0.015

drawCursor :: Scene -> Font -> Surface -> Double -> IO ()
drawCursor scene ft screen beat = 
  do  
     let colour  = rgbColor (foo r) (foo g) (foo b)
     fillRect screen (Just $ Rect x y w h) colour
     return ()
  where (x,y) = toScreen $ cursor scene
        (w,h) = toScreen (blankWidth, 0.035)
        RGB r g b = hsv (hu*360) 0.7 0.99999
        foo x = floor $ x * 256
        hu = ((beat) `mod'` 1)


drawScene :: Scene -> Font -> Surface -> Double -> IO ()
drawScene scene font screen beat = 
  do mapM_ (drawTree scene font screen beat) top
     mapM_ (\i -> 
             do let (x, y) = toScreen $ location i
                    (w, h) = toScreen $ size i
                fillRect screen (Just $ Rect x y w h) (Pixel 0x00333333)
                message <- renderTextSolid font (token i) textColor
                applySurface 
                  (floor $ (fromIntegral screenWidth) * (fst $ location i)) 
                  (floor $ (fromIntegral screenHeight) * (snd $ location i)) 
                  message screen Nothing
           ) (source scene)
     drawCursor scene font screen beat
  where top = filter (T.hasChild) $ parsed scene
        textColor = Color 255 255 255

drawTree :: Scene -> Font -> Surface -> Double -> T.Datum -> IO ()
drawTree scene font screen beat d = 
  do mapM_ drawLink links
  where links = tails $ d:(T.children (parsed scene) d)
        drawLink [] = return ()
        drawLink (_:[]) = return ()
        drawLink ds@(a:b:_) = do mapM_ (drawLinkLine a b) (enumerate $ reverse $ tail ds)
        drawLinkLine a b (n, x) = 
          drawPat n x1 y1 x2 y2 p screen beat
          where (x1, y1) | a == d = bottomRight w
                         | otherwise = T.location a
                (x2, y2) = T.location b
                p = pat $ wordByDatum (source scene) x
        w = wordByDatum (source scene) d


wordByDatum :: [Word] -> T.Datum -> Word
wordByDatum ws d = wordByIdent ws (T.ident d) 
 
drawPat :: Int -> Float -> Float -> Float -> Float -> Maybe (Pattern (Colour Double)) -> Surface -> Double -> IO ()
drawPat n x1 y1 x2 y2 (Nothing) screen _ = 
  do (thickLine True n 0.008 x2 y2 x1 y1) screen lineColor
     return ()
  where lineColor = rgbColor 127 127 127

drawPat n x1 y1 x2 y2 (Just p) screen beat = mapM_ drawEvents es
  where es = map (\((s,e), evs) -> ((max s pos, min e (pos + 1)), evs)) $ arc (segment2 p) (pos, pos + 1)
        constrain x = min (pos + 1) $ max x pos
        pos = toRational $ beat
        xd = x2 - x1
        yd = y2 - y1
        drawEvents ((s,e), cs) = 
          mapM_ (\(n', (h, c)) -> drawEvent h (s,e) c n' (length cs)) (enumerate cs)
        drawEvent h (s,e) c n' scale = 
          (thickLine h (n*scale+n') (0.008/ (fromIntegral scale))
           (x1 + (xd * fromRational (e-pos)))
           (y1 + (yd * fromRational (e-pos)))
           (x1 + (xd * fromRational (s-pos))) 
           (y1 + (yd * fromRational (s-pos)))
          ) 
          screen (colourToPixel c)

segment2 :: Pattern a -> Pattern [(Bool, a)]
segment2 p = Pattern $ \(s,e) -> filter (\((s',e'),_) -> s' < e && e' > s) $ groupByTime (segment2' (arc (fmap (\x -> (True, x)) p) (s,e)))


segment2' :: [Time.Event (Bool, a)] -> [Time.Event (Bool, a)]
segment2' es = foldr split2 es pts
  where pts = nub $ points es

split2 :: Time.Time -> [Time.Event (Bool, a)] -> [Time.Event (Bool, a)]
split2 _ [] = []
split2 t ((ev@((s,e), (h,v))):es) | t > s && t < e = ((s,t),(h,v)):((t,e),(False,v)):(split t es)
                                  | otherwise = ev:split2 t es

thickLine :: Bool -> Int -> Float -> Float -> Float -> Float -> Float -> (Surface -> Pixel -> IO ())
thickLine h n thickness x1 y1 x2 y2 = 
  \s p -> do SDLP.filledPolygon s coords p
             SDLP.aaPolygon s coords p
             line s
             return ()
  where x = x2 - x1
        y = y2 - y1
        l = sqrt $ x*x+y*y
        line s | h = do line' s
                        return ()
               | otherwise = return ()
        line' s = SDLP.aaLine s (fst $ coords !! 1) (snd $ coords !! 1) (fst $ coords !! 2) (snd $ coords !! 2) (Pixel 0x000000ff)
        incX = (fromIntegral n) * (thickness * (y2-y1) / l)
        incY = (fromIntegral n) * (thickness * (x1-x2) / l)
        ox = (thickness * (y2-y1) / l)
        oy = (thickness * (x1-x2) / l)
        coords = map toScreen16 [(x1 + ox + incX, y1 + oy + incY),
                                 ((x2 + ox + incX), (y2 + oy + incY)),
                                 (((x2 ) + incX), ((y2) + incY)),
                                 (x1 + incX , y1 + incY)
                                ]

thickLineArrow :: Int -> Float -> Float -> Float -> Float -> Float -> (Surface -> Pixel -> IO Bool)
thickLineArrow n thickness x1 y1 x2 y2 = 
  \s p -> do SDLP.filledPolygon s (map toScreen16 coords) p
             SDLP.aaPolygon s (map toScreen16 coords) p
             SDLP.filledPolygon s (map toScreen16 arrowCoords) p
             SDLP.aaPolygon s (map toScreen16 arrowCoords) p
  where x = x2 - x1
        y = y2 - y1
        headx = (x/l) / 60
        heady = (y/l) / 60
        l = sqrt $ x*x+y*y
        incX = (fromIntegral n) * (thickness * (y2-y1) / l) * 2
        incY = (fromIntegral n) * (thickness * (x1-x2) / l) * 2
        ox = (thickness * (y2-y1) / l)/2
        oy = (thickness * (x1-x2) / l)/2
        coords = [(x1 + ox + incX, y1 + oy + incY),
                  ((x2 + ox + incX) - headx, (y2 + oy + incY) - heady),
                  (((x2 - ox) + incX) - headx, ((y2 - oy) + incY) - heady),
                  (x1 + incX - ox, y1 + incY - oy)
                 ]
        arrowCoords = [(((x2 + ox) + incX) - headx, 
                        ((y2 + oy) + incY) - heady),
                       (((x2 - ox) + incX) - headx,
                        ((y2 - oy) + incY) - heady),
                       (x2+incX, y2+incY)
                      ]


loop :: AppEnv ()
loop = do
    quit <- whileEvents $ act
    screen <- screen `liftM` ask
    font <- font `liftM` ask
    tempoM <- tempoMV `liftM` ask
    fps <- fr `liftM` ask
    tempo <- liftIO $ readMVar tempoM
    beat <- liftIO $ beatNow tempo
    scene <- get
    liftIO $ do
        bgColor  <- (mapRGB . surfaceGetPixelFormat) screen 0x00 0x00 0x00  
        clipRect <- Just `liftM` getClipRect screen
        fillRect screen clipRect bgColor
        SDLP.aaLine screen (floor $ xDivider * (fromIntegral screenWidth)) 0 (floor $ xDivider * (fromIntegral screenWidth)) (fromIntegral screenHeight) (Pixel 0x00ffffff)
        drawScene scene font screen beat 
        Graphics.UI.SDL.flip screen
        FR.delay fps
    unless quit loop
      where act e = do scene <- get 
                       scene' <- handleEvent scene e
                       put $ scene'

whileEvents :: MonadIO m => (Event -> m ()) -> m Bool
whileEvents act = do
    event <- liftIO pollEvent
    case event of
        Quit -> return True
        NoEvent -> return False
        _       ->  do
            act event
            whileEvents act

runLoop :: AppConfig -> Scene -> IO ()
runLoop = evalStateT . runReaderT loop

textSize :: String -> Font -> IO ((Float,Float))
textSize text font = 
  do message <- renderTextSolid font text (Color 0 0 0)
     return (fromScreen (surfaceGetWidth message, surfaceGetHeight message))

newWord :: Int -> String -> (Float, Float) -> Font -> WordStatus -> IO (Word)
newWord ident text location font status = setSize wd font
  where wd = Word ident text location undefined Nothing status Nothing

setSize :: Word -> Font -> IO Word
setSize wd@(Word {token = ""}) _ = return wd {size = (0,0)}
setSize wd font = do sz <- textSize (token wd) font
                     return $ wd {size = sz}

wordMenu :: Font -> [String] -> IO ([Word])
wordMenu font ws = mapM addWord (enumerate ws)
  where addWord (n, w) = 
          newWord n w (xDivider + 0.005 + ((fromIntegral $ n `mod` 2) * (1 - xDivider) / 2), (fromIntegral (n `div` 2)) * 0.037) font MenuItem

things = (map fst T.functions)

run = withInit [InitEverything] $ 
      do result <- TTFG.init
         if not result
           then putStrLn "Failed to init ttf"
           else do env <- initEnv
                   ws <- wordMenu (font env) things
                   let scene = parseScene $ Scene ws [] (0,0) (0.5,0.5)
                   --putStrLn $ show scene
                   runLoop env scene


colourToPixel :: Colour Double -> Pixel
colourToPixel c =  rgbColor (floor $ 256*r) (floor $ 256* g) (floor $ 256*b)
  where (RGB r g b) = toSRGB c

fi a = fromIntegral a

rgbColor :: GHC.Word.Word8 -> GHC.Word.Word8 -> GHC.Word.Word8 -> Pixel
rgbColor r g b = Pixel (shiftL (fi r) 24 .|. shiftL (fi g) 16 .|. shiftL (fi b) 8 .|. (fi 255))

pixel :: Surface -> (GHC.Word.Word8,GHC.Word.Word8,GHC.Word.Word8) -> IO Pixel
pixel surface (r,g,b) = mapRGB (surfaceGetPixelFormat surface) r g b
