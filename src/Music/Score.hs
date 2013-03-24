
{-# LANGUAGE
    TypeFamilies,
    GeneralizedNewtypeDeriving,
    DeriveFunctor,
    DeriveFoldable,     
    ScopedTypeVariables,
    FlexibleInstances,
    NoMonomorphismRestriction #-}

-------------------------------------------------------------------------------------
-- |
-- Copyright   : (c) Hans Hoglund 2012
--
-- License     : BSD-style
--
-- Maintainer  : hans@hanshoglund.se
-- Stability   : experimental
-- Portability : portable
--
-- Provides a musical score represenation.
--
-------------------------------------------------------------------------------------

module Music.Score (

        -- * Basic types
{-
        ** Voice
        Voice(..),
-}

        -- ** Time and duration
        Time(..),
        Duration(..),
        HasDuration(..),
        HasOnset(..),

        -- * Delayable class
        Delayable(..),

        -- * Track type
        Track(..),
        -- * Part type
        Part(..),
        -- * Score type
        Score(..),

        -- ** Constructors
        rest,
        note,
        chord,
        melody,
        chords,
        melodies,
        -- chordDelay,
        -- melodyStretch,
        -- chordDelayStretch,

        -- ** Transforming
        delay,
        stretch,
        startAt,
        stopAt,
        compress,
        stretchTo,        

        -- ** Composing
        (|>),
        (<|),
        scat,
        pcat,
        -- (<||),
        -- (||>),
        -- (<<|),
        -- (|>>),
        -- sustain,
        -- overlap,
        -- prolong,
        -- anticipate,

        -- ** Performance
        performAbsolute,
        performRelative,
        
{-
        -- ** Decomposing
        voices,
        numVoices,
        setVoice,
-}
        
        -- * Utility         
        -- ** MIDI export
        HasMidi(..),
        toMidi,
        writeMidi,
        playMidi,
        playMidiIO,

        -- ** MusicXML export
        XmlScore,
        XmlMusic,
        HasMusicXml(..),
        toXml,
        writeXml,
        openXml
)
where

{-
    TODO
        Monoid instance for Part is strange
        Can be bad if used with |> etc, we should add some constraint to prevent this
        Delayable?
            'delay' is really similar to (.+^)
            But (.-.) does not really make sense, or does it?
       Split and reverse
       Zipper applicative (for appying dynamic and articulation transformations etc)
            
-}  

import Prelude hiding (foldr, concat, foldl, mapM, concatMap, maximum, sum, minimum)

import Data.Semigroup
import Data.Ratio
import Control.Applicative
import Control.Monad (ap, join, MonadPlus(..))
import Data.Maybe
import Data.Either
import Data.Foldable
import Data.Traversable
import Data.Function (on)
import Data.Ord (comparing)

import Data.VectorSpace
import Data.AffineSpace
import Data.Basis

import Data.Functor.Identity
import Text.Parsec hiding ((<|>))
import Text.Parsec.Pos

import System.Posix -- debug
import System.IO
import System.IO.Unsafe --debug

import Music.Pitch.Literal
import Music.Dynamics.Literal

import Control.Reactive
import Control.Reactive.Midi

import qualified Codec.Midi as Midi
import qualified Music.MusicXml.Simple as Xml
import qualified Data.Map as Map
import qualified Data.List as List


{-
-------------------------------------------------------------------------------------
-- Voice
-------------------------------------------------------------------------------------

newtype Voice = Voice { getVoice::Int }
    deriving (Eq, Ord, Show, Num, Enum, Real, Integral)
-}


-------------------------------------------------------------------------------------
-- Time and duration
-------------------------------------------------------------------------------------

-- |
-- This type represents absolute time. This means seconds elapsed since a known 
-- reference time. The reference time can be anything, but is usually the 
-- the beginning of the musical performance.
--
-- Times forms an affine space with durations as the underlying vector space.
--
newtype Time = Time { getTime::Rational }
    deriving (Eq, Ord, {-Show, -}Num, Enum, Real, Fractional, RealFrac)
    -- Note: no Floating as we want to be able to switch to rational

-- |
-- This type represents relative time in seconds.
--
newtype Duration = Duration { getDuration::Rational }                                  
    deriving (Eq, Ord, {-Show, -}Num, Enum, Real, Fractional, RealFrac)
    -- Note: no Floating as we want to be able to switch to rational

-- TODO for debugging
instance Show Time where show = show . getTime
instance Show Duration where show = show . getDuration

instance AdditiveGroup Time where
    zeroV = 0
    (^+^) = (+)
    negateV = negate

instance VectorSpace Time where
    -- FIXME shouldn't this be Duration?
    type Scalar Time = Time
    (*^) = (*)

instance InnerSpace Time where (<.>) = (*)

instance  AffineSpace Time where
    type Diff Time = Duration
    a .-. b =  t2d $ a - b      where t2d = Duration . getTime
    a .+^ b =  a + d2t b        where d2t = Time . getDuration

instance AdditiveGroup Duration where
    zeroV = 0
    (^+^) = (+)
    negateV = negate

instance VectorSpace Duration where
    type Scalar Duration = Duration
    (*^) = (*)

instance InnerSpace Duration where (<.>) = (*)


class HasDuration a where
    duration :: a -> Duration

class HasOnset a where
    onset  :: a -> Time
    offset :: a -> Time


-------------------------------------------------------------------------------------
-- Delayable class
-------------------------------------------------------------------------------------

-- |
-- Delayable values. This is really similar to 'AffineSpace', except that there
-- is no '.-.'.
-- 
class Delayable a where

    -- |
    -- Delay a score.
    -- > Duration -> Score a -> Score a
    -- 
    delay :: Duration -> a -> a

-- |
-- Move a score to start at a specific time.
-- 
-- > Duration -> Score a -> Score a
-- 
t `startAt` x = delay d x where d = t .-. onset x

-- |
-- Move a score to stop at a specific time.
-- 
-- > Duration -> Score a -> Score a
-- 
t `stopAt`  x = delay d x where d = t .-. offset x



-------------------------------------------------------------------------------------
-- Track type
-------------------------------------------------------------------------------------

-- |
-- A track is a sorted list of absolute-time occurences.
--
-- Track is a 'Monoid' under parallel compisiton. 'mempty' is the empty track and 'mappend'
-- interleaves values.
--
-- Track has an 'Applicative' instance derived from the 'Monad' instance.
--
-- Track is a 'Monad'. 'return' creates a track containing a single value at time
-- zero, and '>>=' transforms the values of a track, allowing the addition and
-- removal of values relative to the time of the value. Perhaps more intuitively,
-- 'join' delays each inner track to start at the offset of an outer track, then
-- removes the intermediate structure. 
--
-- > let t = Track [(0, 65),(1, 66)] 
-- >
-- > t >>= \x -> Track [(0, 'a'), (10, toEnum x)]
-- >
-- >   ==> Track {getTrack = [ (0.0,  'a'),
-- >                           (1.0,  'a'),
-- >                           (10.0, 'A'),
-- >                           (11.0, 'B') ]}
--
-- Track is an instance of 'VectorSpace' using parallel composition as addition, 
-- and time scaling as scalar multiplication. 
--
newtype Track a = Track { getTrack :: [(Time, a)] }
    deriving (Eq, Ord, Show, Functor, Foldable)

instance Semigroup (Track a) where
    (<>) = mappend

-- Equivalent to the deriving Monoid, except for the sorted invariant.
instance Monoid (Track a) where
    mempty = Track []
    Track as `mappend` Track bs = Track (as `m` bs)
        where
            m = mergeBy (comparing fst)

instance Applicative Track where
    pure  = return
    (<*>) = ap

instance Monad Track where
    return a = Track [(0, a)]
    a >>= k = join' . fmap k $ a
        where
            join' (Track ts) = foldMap (uncurry delay') $ ts
            delay' t = delay (Duration . getTime $ t)

instance Alternative Track where
    empty = mempty
    (<|>) = mappend

-- Satisfies left distribution
instance MonadPlus Track where
    mzero = mempty
    mplus = mappend

instance AdditiveGroup (Track a) where
    zeroV   = mempty
    (^+^)   = mappend
    negateV = id

instance VectorSpace (Track a) where
    type Scalar (Track a) = Time
    n *^ Track tr = Track . (fmap (first (n*^))) $ tr

instance Delayable (Track a) where
    d `delay` Track tr = Track . fmap (first (.+^ d)) $ tr

instance HasOnset (Track a) where
    onset  (Track []) = 0
    onset  (Track xs) = minimum (fmap on xs)  where on   (t,x) = t
    offset (Track []) = 0
    offset (Track xs) = maximum (fmap off xs) where off  (t,x) = t

instance HasDuration (Track a) where
    duration x = offset x .-. onset x

--    offset x = maximum (fmap off x)   where off (t,x) = t

-------------------------------------------------------------------------------------
-- Part type
-------------------------------------------------------------------------------------

-- |
-- A part is a sorted list of relative-time notes and rests.
--
-- Part is a 'Monoid' under sequential compisiton. 'mempty' is the empty part and 'mappend'
-- appends parts.
--
-- Track has an 'Applicative' instance derived from the 'Monad' instance.
--
-- Part is a 'Monad'. 'return' creates a part containing a single value of duration
-- one, and '>>=' transforms the values of a part, allowing the addition and
-- removal of values under relative duration. Perhaps more intuitively, 'join' scales 
-- each inner part to the duration of the outer part, then removes the 
-- intermediate structure. 
--
-- > let p = Part [(1, Just 0), (2, Just 1)] :: Part Int
-- >
-- > p >>= \x -> Part [ (1, Just $ toEnum $ x+65), 
-- >                    (3, Just $ toEnum $ x+97) ] :: Part Char
-- >
-- >     ===> Part {getPart = [ (1 % 1,Just 'A'),
-- >                            (3 % 1,Just 'a'),
-- >                            (2 % 1,Just 'B'),
-- >                            (6 % 1,Just 'b') ]}
--
-- Part is a 'VectorSpace' using sequential composition as addition, and time scaling
-- as scalar multiplication.
--
newtype Part a = Part { getPart :: [(Duration, a)] }
    deriving (Eq, Ord, Show, Functor, Foldable, Monoid)

instance Semigroup (Part a) where
    (<>) = mappend

instance Applicative Part where
    pure  = return
    (<*>) = ap

instance Monad Part where
    return a = Part [(1, a)]
    a >>= k = join' $ fmap k a
        where
            join' (Part ps) = foldMap (uncurry (*^)) ps

instance AdditiveGroup (Part a) where
    zeroV   = mempty
    (^+^)   = mappend
    negateV = id

instance VectorSpace (Part a) where
    type Scalar (Part a) = Duration
    n *^ Part as = Part (fmap (first (n*^)) as)

instance HasDuration (Part a) where
    duration (Part []) = 0
    duration (Part as) = sum (fmap fst as)


-------------------------------------------------------------------------------------
-- Score type
-------------------------------------------------------------------------------------

-- |
-- A score is a list of absolute time notes and rests. A rest is a duration and 
-- a note is a value and a duration.
--
-- Score is a 'Monoid' under parallel compisiton. 'mempty' is a score of no parts.
-- For sequential composition of scores, use '|>'.
--
-- Score has an 'Applicative' instance derived from the 'Monad' instance. Not sure it is useful.
--
-- Score is a 'Monad'. 'return' creates a score containing a single note of
-- duration one, and '>>=' transforms the values of a score, while allowing
-- transformations of time and duration. More intuitively, 'join' scales and
-- offsets each inner score to fit into an outer score, then removes the intermediate
-- structure. 
--
-- > let s = Score [(0, 1, Just 0), (1, 2, Just 1)] :: Score Int
-- >
-- > s >>= \x -> Score [ (0, 1, Just $ toEnum $ x+65), 
-- >                     (1, 3, Just $ toEnum $ x+97) ] :: Score Char
-- >
-- >     ===> Score {getScore = [ (0 % 1, 1 % 1, Just 'A'),
-- >                              (1 % 1, 3 % 1, Just 'a'),
-- >                              (1 % 1, 2 % 1, Just 'B'),
-- >                              (3 % 1, 6 % 1, Just 'b') ]}
--
-- Track is an instance of 'VectorSpace' using parallel composition as addition, 
-- and time scaling as scalar multiplication. 
--
newtype Score a  = Score { getScore :: [(Time, Duration, Maybe a)] }
    deriving (Eq, Ord, Show, Functor, Foldable)

-- instance Eq a => Eq (Score a) where
--     a == b = performAbsolute a == performAbsolute b
-- 
-- instance Ord a => Ord (Score a) where
--     a `compare` b = performAbsolute a `compare` performAbsolute b

instance Semigroup (Score a) where
    (<>) = mappend

-- Equivalent to the deriving Monoid, except for the sorted invariant.
instance Monoid (Score a) where
    mempty = Score []
    Score as `mappend` Score bs = Score (as `m` bs)
        where
            m = mergeBy (comparing fst3)
            fst3 (a,b,c) = a

instance Applicative Score where
    pure  = return
    (<*>) = ap

instance Alternative Score where
    empty = mempty
    (<|>) = mappend

-- Satisfies left distribution
instance MonadPlus Score where
    mzero = mempty
    mplus = mappend

instance Monad Score where
    return = note
    a >>= k = join' $ fmap k a
        where  
            join' sc = pcat $ toList $ mapWithTimeDur (\t d -> fmap (delay t . stretch d)) $ sc

mapWithTimeDur :: (Duration -> Duration -> Maybe a -> Maybe b) -> Score a -> Score b
mapWithTimeDur f = Score . fmap (liftTimeDur f) . getScore

liftTimeDur :: (Duration -> Duration -> Maybe a -> Maybe b) -> (Time, Duration, Maybe a) -> (Time, Duration, Maybe b)
liftTimeDur f (t,d,x) = case f (t2d t) d x of
    Nothing -> (t,d,Nothing)
    Just y  -> (t,d,Just y)
    where
        t2d = Duration . getTime

instance AdditiveGroup (Score a) where
    zeroV   = mempty
    (^+^)   = mappend
    negateV = id

instance VectorSpace (Score a) where
    type Scalar (Score a) = Duration
    d *^ Score sc = Score . fmap (first3 (^* d2t d) . second3 (^* d)) $ sc
        where
            first3 f (a,b,c) = (f a,b,c)
            second3 f (a,b,c) = (a,f b,c)                      
            d2t = Time . getDuration
            
instance Delayable (Score a) where
    d `delay` Score sc = Score . fmap (first3 (.+^ d)) $ sc
        where
            first3 f (a,b,c) = (f a,b,c)

instance HasOnset (Score a) where
    onset  (Score []) = 0
    onset  (Score xs) = minimum (fmap on xs)  where on  (t,d,x) = t
    offset (Score []) = 0
    offset (Score xs) = maximum (fmap off xs) where off (t,d,x) = t + (Time . getDuration $ d)
        
instance HasDuration (Score a) where
    duration x = offset x .-. onset x            

instance IsPitch a => IsPitch (Score a) where
    fromPitch = pure . fromPitch

instance IsDynamics a => IsDynamics (Score a) where
    fromDynamics = pure . fromDynamics

{-
-- Experimental instance. We want to do something more sophisticated with parts later on.
instance HasBasis (Score a) where
    type Basis (Score a) = Voice
    basisValue p = Score [(p, Part [(1, Nothing)])]
    decompose' s = fromJust . (flip lookup) (decompose s)
    decompose    = fmap (second duration) . getScore
-}


performAbsolute :: Score a -> [(Time, Duration, a)]
performAbsolute = removeRests . getScore
    where
        removeRests = catMaybes . fmap mbRest
        mbRest (t,d,Just x)  = Just (t,d,x)
        mbRest (t,d,Nothing) = Nothing

performRelative :: Score a -> [(Time, Duration, a)]
performRelative = toRel . performAbsolute
    where
        toRel = snd . mapAccumL g 0
        g now (t,d,x) = (t, (t-now,d,x))
            

-------------------------------------------------------------------------------------
-- Constructors
-------------------------------------------------------------------------------------

-- |
-- Create a score of duration 1 with no values.
--
rest :: Score a
-- rest = Score [Part [(1, Nothing)]]
rest = Score [(0,1,Nothing)]

-- |
-- Create a score of duration 1 with the given value.
--
-- Equivalent to 'pure' and 'return'.
--
note :: a -> Score a
note x = Score [(0,1,Just x)]
-- note x = Score [Part [(1, Just x)]]

-- | Creates a score containing the given elements, composed in sequence.
melody :: [a] -> Score a
melody = scat . map note

-- | Creates a score containing the given elements, composed in parallel.
chord :: [a] -> Score a
chord = pcat . map note

-- | Creates a score from a the given melodies, composed in parallel.
melodies :: [[a]] -> Score a
melodies = pcat . map melody

-- | Creates a score from a the given chords, composed in sequence.
chords :: [[a]] -> Score a
chords = scat . map chord

-- | Like 'melody', but stretching each note by the given factors.
melodyStretch :: [(Duration, a)] -> Score a
melodyStretch = scat . map ( \(d, x) -> stretch d $ note x )

-- | Like 'chord', but delays each note the given amounts.
chordDelay :: [(Duration, a)] -> Score a
chordDelay = pcat . map ( \(t, x) -> delay t $ note x )

-- | Like 'chord', but delays and stretches each note the given amounts.
chordDelayStretch :: [(Duration, Duration, a)] -> Score a
chordDelayStretch = pcat . map ( \(t, d, x) -> delay t . stretch d $ note x )

-- -- | Like chord, but delaying each note the given amount.
-- arpeggio :: t -> [a] -> Score a
-- arpeggio t xs = chordDelay (zip [0, t ..] xs)


-------------------------------------------------------------------------------------
-- Transformations
-------------------------------------------------------------------------------------

-- |
-- Stretch a score. Equivalent to '*^'.
-- 
-- > Duration -> Score a -> Score a
-- 
stretch :: VectorSpace v => Scalar v -> v -> v
stretch = (*^)

-- |
-- Compress a score. Flipped version of '^/'.
-- 
-- > Duration -> Score a -> Score a
-- 
compress :: (VectorSpace v, s ~ Scalar v, Fractional s) => s -> v -> v
compress = flip (^/)

-- | 
-- Stretch to the given duration. 
-- 
-- > Duration -> Score a -> Score a
-- 
stretchTo :: (VectorSpace a, HasDuration a, Scalar a ~ Duration) => Duration -> a -> a
t `stretchTo` x = (t / duration x) `stretch` x 


-------------------------------------------------------------------------------------
-- Composition
-------------------------------------------------------------------------------------

infixr 6 |>
infixr 6 <|

-- |
-- Compose in sequence.
--
-- To compose in parallel, use '<|>' or '<>'.
--
-- > Score a -> Score a -> Score a
(|>) :: (Semigroup a, Delayable a, HasOnset a) => a -> a -> a
a |> b =  a <> startAt (offset a) b
-- a |< b =  a <> stopAt (onset a) b


-- |
-- Compose in reverse sequence. 
--
-- To compose in parallel, use '<|>' or '<>'.
--
-- > Score a -> Score a -> Score a
(<|) :: (Semigroup a, Delayable a, HasOnset a) => a -> a -> a
a <| b =  b |> a

-- |
-- Sequential concatentation.
--
-- > [Score t] -> Score t
scat :: (Monoid a, Semigroup a, Delayable a, HasOnset a) => [a] -> a
scat = foldr (|>) mempty

-- |
-- Parallel concatentation. Identical to 'mconcat'.
--
-- > [Score t] -> Score t
-- pcat :: Monoid a => [a] -> a
pcat = mconcat

infixr 7 <<|
infixr 7 |>>
infixr 7 <||
infixr 7 ||>

(<||) = sustain
(||>) = flip sustain
(|>>) = overlap
(<<|) = flip overlap    

-- | 
-- Like '<>', but scaling the second agument to the duration of the first.
-- 
-- > Score a -> Score a -> Score a
--
sustain :: (Semigroup a, VectorSpace a, HasDuration a, Scalar a ~ Duration) => a -> a -> a
x `sustain` y = x <> (duration x) `stretchTo` y

-- Like '<>', but truncating the second agument to the duration of the first.
-- prolong x y = x <> before (duration x) y

-- |
-- Like '|>', but moving second argument halfway to the offset of the first.
--
-- > Score a -> Score a -> Score a
--
overlap :: (Semigroup a, Delayable a, HasDuration a) => a -> a -> a
x `overlap` y  =  x <> delay t y where t = duration x / 2    

-- |
-- Like '|>' but with a negative delay on the second element.
-- 
-- > Duration -> Score a -> Score a -> Score a
-- 
anticipate :: (Semigroup a, Delayable a, HasDuration a, HasOnset a) => Duration -> a -> a -> a
anticipate t x y = x |> delay t' y where t' = (duration x - t) `max` 0





-------------------------------------------------------------------------------------
-- Decomposition
-------------------------------------------------------------------------------------

{-
-- | 
-- Returns the voices in the given score.
--
voices :: Score a -> [Voice]
voices = fmap fst . decompose

-- | 
-- Returns the number of voices in the given score.
--
numVoices :: Score a -> Int
numVoices = length . voices
-}
 

-------------------------------------------------------------------------------------

-- |
-- Class of types that can be converted to MIDI.
--
-- Numeric types are interpreted as notes with a default velocity, pairs are
-- interpreted as @(pitch, velocity)@ pairs.
--
-- Minimal definition: 'getMidi'. Given 'getMidiScore', 'getMidi' can be implemented
-- as @getMidiScore . return@.
--
class HasMidi a where
    -- | Convert a value to a MIDI score.
    --   Typically, generates an /on/ event using 'note' followed by an optional /off/ event.
    getMidi :: a -> Score Midi.Message

    -- | Convert a score to a MIDI score.
    --   The default definition can be overriden for efficiency.
    getMidiScore :: Score a -> Score Midi.Message
    getMidiScore = (>>= getMidi)

instance HasMidi Midi.Message where
    getMidi = return

instance HasMidi ()                      where   getMidi = getMidi . toInteger . const 60
instance HasMidi Double                  where   getMidi = getMidi . toInteger . round
instance HasMidi Int                     where   getMidi = getMidi . toInteger    
instance Integral a => HasMidi (Ratio a) where   getMidi = getMidi . toInteger . round    

instance HasMidi Integer where
    getMidi x = note (Midi.NoteOn 0 (fromIntegral x) 100) |> note (Midi.NoteOff 0 (fromIntegral x) 100)

instance HasMidi (Integer, Integer) where
    getMidi (p,v) = note (Midi.NoteOn 0 (fromIntegral p) (fromIntegral v)) |> note (Midi.NoteOff 0 (fromIntegral p) (fromIntegral v))


-- |
-- Convert a score to a MIDI file representaiton.
--    
toMidi :: HasMidi a => Score a -> Midi.Midi
toMidi score = Midi.Midi fileType divisions' [controlTrack, eventTrack]
    where                                                        
        endPos          = 10000
        fileType        = Midi.MultiTrack       
        divisions       = 1024
        divisions'      = Midi.TicksPerBeat divisions
        controlTrack    = [(0, Midi.TempoChange 1000000), (endPos, Midi.TrackEnd)]
        eventTrack      = events <> [(endPos, Midi.TrackEnd)] 

        events :: [(Midi.Ticks, Midi.Message)]
        events          = (\(t,_,x) -> (round (t * divisions), x)) <$> performance

        performance :: [(Time, Duration, Midi.Message)]
        performance     = performRelative (getMidiScore score)

        -- FIXME arbitrary endTime (files won't work without this...)
        -- TODO handle voice

-- |
-- Convert a score MIDI and write to a file.
--    
writeMidi :: HasMidi a => FilePath -> Score a -> IO ()
writeMidi path sc = Midi.exportFile path (toMidi sc)

-- |
-- Convert a score to a MIDI event.
--    
playMidi :: HasMidi a => Score a -> Event MidiMessage
playMidi x = midiOut midiDest $ playback trig (pure $ toTrack $ rest^*0.2 |> x)
    where
        trig        = accumR 0 ((+ 0.005) <$ pulse 0.005)        
        toTrack     = fmap (\(t,_,m) -> (t,m)) . performAbsolute . getMidiScore
        midiDest    = fromJust $ unsafeGetReactive (findDestination  $ pure "Graphic MIDI")
        -- FIXME hardcoded output...

-- |
-- Convert a score to a MIDI event and run it.
--    
playMidiIO :: HasMidi a => Score a -> IO ()
playMidiIO = runLoop . playMidi

        


-------------------------------------------------------------------------------------

-- fj1 = sc $ melody [c,d] |> melody [eb,d]^/2 |> c
fj1 = sc $ melody [c,d] |> melody [eb,d]^/2 |> c^/2 |> rest^/2

fj2 = sc $ melody [eb,f] |> g^*2
fj3 = sc $ g^*(3/4) |> ab^*(1/4) |> melody [g,f,eb,d] ^/2 |> c
fj4 = c |> g_ |> c^*2
fj = (rep 2 fj1 |> rep 2 fj2 |> rep 2 fj3 |> rep 2 fj4)^/2
fj' = fj <> delay 4 fj <> delay 8 fj <> delay 12 fj

type XmlScore = Xml.Score
type XmlMusic = Xml.Music

-- |
-- Class of types that can be converted to MusicXML.
--
class HasMusicXml a where          
    -- getPartNum      :: a -> Int         
    -- getDynamics     :: a -> Maybe a
    -- getArticulation :: a -> Maybe a

    -- | Convert a single note or rest.
    getXmlNote      :: Duration -> a -> XmlMusic

instance HasMusicXml ()                      where   getXmlNote d = getXmlNote d . (toInteger . const 60)
instance HasMusicXml Double                  where   getXmlNote d = getXmlNote d . (toInteger . round)
instance HasMusicXml Int                     where   getXmlNote d = getXmlNote d . toInteger    
instance Integral a => HasMusicXml (Ratio a) where   getXmlNote d = getXmlNote d . (toInteger . round)    

instance HasMusicXml Integer where
    getXmlNote d p = Xml.note (spell (fromIntegral p)) d'
        where
            d' = (fromRational . toRational $ d)   
            
            step xs p = xs !! (p `mod` length xs)
            fromStep xs p = fromMaybe (length xs - 1) $ List.findIndex (>= p) xs
            scaleFromSteps = snd . List.mapAccumL add 0
                where
                    add a x = (a + x, a + x)
            major = scaleFromSteps [0,2,2,1,2,2,2,1]

            spell :: Int -> Xml.Pitch
            spell p = (toEnum pitchClass, if (alteration == 0) then Nothing else Just (fromIntegral alteration), fromIntegral octave) -- FIXME
                where
                    octave     = (p `div` 12) - 1
                    semitone   = p `mod` 12
                    pitchClass = fromStep major semitone
                    alteration = semitone - step major pitchClass


-- |
-- Convert a score to a MusicXML representaiton. 
-- 
toXml :: (Show a, HasMusicXml a) => Score a -> XmlScore
toXml = Xml.fromPart "Title" "Composer" "Part" . fmap translBar . fmap (fmap removeTime) . separateBars . addRests . performAbsolute
    where
        removeTime (t,d,x) = (d,x)

        -- TODO after performAbsolute, separate parts, then separate each part into note layer and dynamic layer tracks
        
        -- For each note layer: add rests, separate bars, remove time and create [Rhythm (Maybe a)]
        -- For each dynamics layer: add rests, separate bars, remove time and create [(BarTime, a)]
        -- Somehow merge dynamics layer back into note layer to get [Rhythm (Either (Maybe a) Dynamic)]
        -- Convert to XmlMusic
        
        -- Merge parts using Xml.fromParts

-- |
-- Convert a score to MusicXML and write to a file. 
-- 
writeXml :: (Show a, HasMusicXml a) => FilePath -> Score a -> IO ()
writeXml path sc = writeFile path (Xml.showXml $ toXml sc)

-- |
-- Convert a score to MusicXML and open it. 
-- 
openXml :: (Show a, HasMusicXml a) => Score a -> IO ()
openXml sc = do
    writeXml "test.xml" sc
    execute "open" ["-a", "/Applications/Sibelius 6.app/Contents/MacOS/Sibelius 6", "test.xml"]

-- | 
-- Given a rest-free, one-part score, add rests.
--
-- Note that these are not the padding rests used by Score, but the real-thing, i.e. the result will have
-- no empty space.
--
addRests :: [(Time, Duration, a)] -> [(Time, Duration, Maybe a)]
addRests = concat . snd . mapAccumL g 0
    where
        g pos (t,d,x) 
            | pos == t   =  (t .+^ d, [(t, d, Just x)])
            | pos <  t   =  (t .+^ d, [(pos, t .-. pos, Nothing), (t, d, Just x)])
            | otherwise  =  error "addRests: Strange pos"
            
-- |
-- Given a set of absolute-time occurences, separate at each zero-time occurence.
-- Note that this require every bar to start with a zero-time occurence.
-- 
separateBars :: (Show a, HasMusicXml a) => [(Time, Duration, Maybe a)] -> [[(Time, Duration, Maybe a)]]
separateBars = fmap (fmap discardBarNumber) . splitAtTimeZero . fmap separateTime
    where  
        discardBarNumber ((bn,bt),d,x) = (fromRational bt, d, x)

        splitAtTimeZero = splitWhile ((== 0) . getBarTime)
        
        separateTime (t,d,x) = ((bn,bt),d,x) where (bn,bt) = properFraction (toRational t)
        
        getBarTime ((bn,bt),_,_) = bt
        -- FIXME assumes bar length of one
        -- FIXME ties?

-- translate one bar
translBar :: (Show a, HasMusicXml a) => [(Duration, Maybe a)] -> Xml.Music
translBar bar = case quantize bar of
    Left e   -> error $ "translBar: Could not quantize this bar: " ++ show e
    Right rh -> translR rh

translR :: HasMusicXml a => Rhythm (Maybe a) -> Xml.Music
translR (RBeat d x)             = translNoteRest (d, x)
translR (RDotted n (RBeat d x)) = translNoteRest (dotMod n * d, x)
translR (RTuplet m r)           = Xml.tuplet (fromIntegral $ denominator $ getDuration $ m) (fromIntegral $ numerator $ getDuration m) (translR r)
translR (RSeq rs)               = mconcat $ map translR rs

translNoteRest :: HasMusicXml a => (Duration, Maybe a) -> Xml.Music
translNoteRest (d, Just p)  = getXmlNote d p
translNoteRest (d, Nothing) = getXmlRest d

getXmlRest d = Xml.rest d' where d' = (fromRational . toRational $ d)   




data Rhythm a 
    = RBeat       Duration a                    -- d is divisible by 2
    | RDotted     Int (Rhythm a)
    | RTuplet     Duration (Rhythm a)           -- d is 2/3, 4/5, 4/6, 4/7, 8/9, 8/10, 8/11 ...
    | RInvTuplet  Duration (Rhythm a)           -- d is 3/2,      6/4
    | RSeq        [Rhythm a]                    
    deriving (Eq, Show)

instance AdditiveGroup (Rhythm a) where
    zeroV   = error "No zeroV for (Rhythm a)"
    (^+^)   = error "No ^+^ for (Rhythm a)"
    negateV = error "No negateV for (Rhythm a)"

instance VectorSpace (Rhythm a) where
    type Scalar (Rhythm a) = Duration
    a *^ RBeat d x = RBeat (a*d) x

instance HasDuration (Rhythm a) where
    duration (RBeat d _)        = d
    duration (RDotted n a)      = duration a * dotMod n
    duration (RTuplet c a)      = duration a * c
    -- duration (RInvTuplet c a)   = duration a * c
    duration (RSeq as)          = sum (fmap duration as)    

quantize :: Show a => [(Duration, a)] -> Either String (Rhythm a)
quantize = quantize' (atEnd rhythm)

testq :: [Duration] -> Either String (Rhythm ())
testq = quantize' (atEnd rhythm) . fmap (\x->(x,()))

atEnd p = do
    x <- p
    notFollowedBy anyToken <?> "end of input"
    return x

dotMod :: Int -> Duration
dotMod n = dotMods !! (n-1)

-- [3/2, 7/4, 15/8, 31/16 ..]
dotMods :: [Duration]
dotMods = zipWith (/) (fmap pred $ drop 2 times2) (drop 1 times2)
    where
        times2 = iterate (*2) 1

tupletMods :: [Duration]
tupletMods = [2/3, 4/5, {-4/6,-} 4/7, 8/9]

data RState = RState {
        timeMod :: Duration,
        -- notatedDur * timeMod = actualDur
        -- 3/2 for dots
        -- 2/3, 4/5, 4/6, 4/7, 8/9, 8/10, 8/11  for ordinary tuplets
        -- 3/2,      6/4                        for inverted tuplets
        tupleDepth :: Int
    }

instance Monoid RState where
    mempty = RState { timeMod = 1, tupleDepth = 0 }
    a `mappend` _ = a

modifyTimeMod :: (Duration -> Duration) -> RState -> RState
modifyTimeMod f (RState tm td) = RState (f tm) td

modifyTupleDepth :: (Int -> Int) -> RState -> RState
modifyTupleDepth f (RState tm td) = RState tm (f td)

-- | 
-- A @RhytmParser a b@ converts (Part a) to b.
type RhythmParser a b = Parsec [(Duration, a)] RState b

quantize' :: RhythmParser a b -> [(Duration, a)] -> Either String b
quantize' p = left show . runParser p mempty ""

match :: (Duration -> a -> Bool) -> RhythmParser a (Rhythm a)
match p = tokenPrim show next test
    where
        show x        = ""
        next pos _ _  = updatePosChar pos 'x'
        test (d,x)    = if p d x then Just (RBeat d x) else Nothing

rhythm :: RhythmParser a (Rhythm a)
rhythm = RSeq <$> Text.Parsec.many1 rhythm'

rhythm' :: RhythmParser a (Rhythm a)
rhythm' = mzero
    <|> beat
    <|> dotted
    <|> tuplet

beat :: RhythmParser a (Rhythm a)
beat = do
    RState tm _ <- getState
    (^/tm) <$> match (const . isDivisibleBy 2 . (/ tm))

dotted :: RhythmParser a (Rhythm a)
dotted = msum . fmap dotted' $ [1..3]               -- max 3 dots

dotted' :: Int -> RhythmParser a (Rhythm a)
dotted' n = do
    modifyState $ modifyTimeMod (* dotMod n)
    b <- beat
    modifyState $ modifyTimeMod (/ dotMod n)
    return (RDotted n b)

tuplet :: RhythmParser a (Rhythm a)
tuplet = msum . fmap tuplet' $ tupletMods

-- tuplet' 2/3 for triplet, 4/5 for quintuplet etc
tuplet' :: Duration -> RhythmParser a (Rhythm a)
tuplet' d = do
    RState _ depth <- getState
    onlyIf (depth < 1) $ do                         -- max 1 nested tuplets
        modifyState $ modifyTimeMod (* d) 
                    . modifyTupleDepth succ
        r <- rhythm        
        modifyState $ modifyTimeMod (/ d) 
                    . modifyTupleDepth pred
        return (RTuplet d r)



    
                                                                                                           
-------------------------------------------------------------------------------------
-- Test stuff
-------------------------------------------------------------------------------------

sc :: Score Double -> Score Double
sc = id

-- prettyScore :: Show a => Score a -> String
-- prettyScore = concatSep " <> " . fmap (\(p,x) -> "("++prettyPart x++")") . getScore

-- prettyPart :: Show a => Part a -> String
-- prettyPart = concatSep " |> " . fmap (\(d,x) -> prettyDur d ++ "*^"++ maybe "rest" prettyVal x) . getPart
--     where                                                                                   
--         prettyVal x = "pure " ++ show x
--         prettyDur (Duration d) = "("++show (numerator d) ++ "/" ++ show (denominator d)++")"

showScore :: Score Double -> String
showScore = show

ssm :: Score Midi.Message -> IO [()]
ssm = mapM putStrLn . fmap show . performAbsolute

ssd :: Score Double -> IO [()]
ssd = mapM putStrLn . fmap show . performAbsolute

spanien :: Score Double
spanien = (c^*3 |> d |> e^*3 |> d |> c^*2 |> g_^*2 |> g_^*4)^/8

rep 0 x = mempty
rep n x = x |> rep (n-1) x


openSib :: Xml.Score -> IO ()
openSib score =
    do  writeFile "test.xml" (Xml.showXml score)
        execute "open" ["-a", "/Applications/Sibelius 6.app/Contents/MacOS/Sibelius 6", "test.xml"]

openTim :: HasMidi a => Score a -> IO ()
openTim sc = do
    Midi.exportFile "test.mid" (toMidi sc)
    execute "timidity" ["test.mid"]

instance IsPitch Integer where
    fromPitch (PitchL (pc, sem, oct)) = fromIntegral $ semitones sem + diatonic pc + (oct+1) * 12
        where
            semitones = maybe 0 round
            diatonic pc = case pc of
                0 -> 0
                1 -> 2
                2 -> 4
                3 -> 5
                4 -> 7
                5 -> 9
                6 -> 11

instance IsPitch Double where
    fromPitch (PitchL (pc, sem, oct)) = fromIntegral $ semitones sem + diatonic pc + (oct+1) * 12
        where
            semitones = maybe 0 round
            diatonic pc = case pc of
                0 -> 0
                1 -> 2
                2 -> 4
                3 -> 5
                4 -> 7
                5 -> 9
                6 -> 11
instance IsDynamics Double where
    fromDynamics (DynamicsL (Just x, _)) = x
    fromDynamics (DynamicsL (Nothing, _)) = error "IsDynamics Double: No dynamics"



















-- Some accumulators etc. Internal for now.



-- Generic stuff (not exported)

list z f [] = z
list z f xs = f xs

first f (x,y)  = (f x, y)
second f (x,y) = (x, f y)

sep :: a -> [a] -> [a]
sep = List.intersperse

concatSep :: [a] -> [[a]] -> [a]
concatSep x = List.concat . sep x

-- | 
-- Group a list into sublists whereever a predicate holds. The matched element
-- is the first in the sublist.
--
-- > splitWhile isSpace "foo bar baz"
-- >    ===> ["foo"," bar"," baz"]
-- >
-- > splitWhile (> 3) [1,5,4,7,0,1,2]
-- >    ===> [[1],[5],[4],[7,0,1,2]]
--
splitWhile :: (a -> Bool) -> [a] -> [[a]]
splitWhile p xs = case splitWhile' p xs of
    []:xss -> xss
    xss    -> xss
    where
        splitWhile' p []     = [[]]
        splitWhile' p (x:xs) = case splitWhile' p xs of
            (xs:xss) -> if p x then []:(x:xs):xss else (x:xs):xss

execute :: FilePath -> [String] -> IO ()
execute program args = do
    forkProcess $ executeFile program True args Nothing
    return ()




logBaseR :: forall a . (RealFloat a, Floating a) => Rational -> Rational -> a
logBaseR k n 
    | isInfinite (fromRational n :: a)      = logBaseR k (n/k) + 1
logBaseR k n 
    | isDenormalized (fromRational n :: a)  = logBaseR k (n*k) - 1
logBaseR k n                         = logBase (fromRational k) (fromRational n)

isDivisibleBy :: (Real a, Real b) => a -> b -> Bool
isDivisibleBy n = (== 0.0) . snd . properFraction . logBaseR (toRational n) . toRational

single x = [x]            
fmap2 = fmap . fmap
fmap3 = fmap . fmap . fmap

dump = mapM putStrLn . fmap show

left f (Left x)  = Left (f x)
left f (Right y) = Right y

mergeBy :: (a -> a -> Ordering) -> [a] -> [a] -> [a]
mergeBy f as bs = List.sortBy f $ as <> bs

onlyIf :: MonadPlus m => Bool -> m b -> m b
onlyIf b p = if b then p else mzero

