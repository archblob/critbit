{-# LANGUAGE BangPatterns, RecordWildCards, ScopedTypeVariables #-}
-- |
-- Module      :  Data.CritBit.Tree
-- Copyright   :  (c) Bryan O'Sullivan 2013
-- License     :  BSD-style
-- Maintainer  :  bos@serpentine.com
-- Stability   :  experimental
-- Portability :  GHC
--
-- "Core" functions that implement the crit-bit tree algorithms.
--
-- I plopped these functions into their own source file to demonstrate
-- just how small the core of the crit-bit tree concept is.
--
-- I have also commented this module a bit more heavily than I usually
-- do, in the hope that the comments will make the code more
-- approachable to less experienced Haskellers.
module Data.CritBit.Core
    (
    -- * Public functions
      insertWithKey
    , insertLookupWithKey
    , insertLookupGen
    , lookupWith
    , updateLookupWithKey
    , leftmost
    , rightmost
    -- * Internal functions
    , calcDirection
    , direction
    , followPrefixes
    , followPrefixesFrom
    , followPrefixesByteFrom
    ) where

import Data.Bits ((.|.), (.&.), complement, shiftR, xor)
import Data.CritBit.Types.Internal
import Data.Word (Word16)

-- | /O(log n)/. Insert with a function, combining key, new value and old value.
-- @'insertWithKey' f key value cb@
-- will insert the pair (key, value) into cb if key does not exist in the map.
-- If the key does exist, the function will insert the pair
-- @(key,f key new_value old_value)@.
-- Note that the key passed to f is the same key passed to insertWithKey.
--
-- > let f key new_value old_value = byteCount key + new_value + old_value
-- > insertWithKey f "a" 1 (fromList [("a",5), ("b",3)]) == fromList [("a",7), ("b",3)]
-- > insertWithKey f "c" 1 (fromList [("a",5), ("b",3)]) == fromList [("a",5), ("b",3), ("c",1)]
-- > insertWithKey f "a" 1 empty                         == singleton "a" 1
insertWithKey :: CritBitKey k => (k -> v -> v -> v) -> k -> v -> CritBit k v
              -> CritBit k v
insertWithKey f k v m = insertLookupGen (flip const) f k v m
{-# INLINABLE insertWithKey #-}

-- | /O(log n)/. Combines insert operation with old value retrieval.
-- The expression (@'insertLookupWithKey' f k x map@)
-- is a pair where the first element is equal to (@'lookup' k map@)
-- and the second element equal to (@'insertWithKey' f k x map@).
--
-- > let f key new_value old_value = length key + old_value + new_value
-- > insertLookupWithKey f "a" 2 (fromList [("a",5), ("b",3)]) == (Just 5, fromList [("a",8), ("b",3)])
-- > insertLookupWithKey f "c" 2 (fromList [(5,"a"), (3,"b")]) == (Nothing, fromList [("a",5), ("b",3), ("c",2)])
-- > insertLookupWithKey f "a" 2 empty                         == (Nothing, singleton "a" 2)
--
-- This is how to define @insertLookup@ using @insertLookupWithKey@:
--
-- > let insertLookup kx x t = insertLookupWithKey (\_ a _ -> a) kx x t
-- > insertLookup "a" 1 (fromList [("a",5), ("b",3)]) == (Just 5, fromList [("a",1), ("b",3)])
-- > insertLookup "c" 1 (fromList [("a",5), ("b",3)]) == (Nothing,  fromList [("a",5), ("b",3), ("c",1)])
insertLookupWithKey :: CritBitKey k
                    => (k -> v -> v -> v)
                    -> k -> v -> CritBit k v
                    -> (Maybe v, CritBit k v)
insertLookupWithKey f k v m = insertLookupGen (,) f k v m
{-# INLINABLE insertLookupWithKey #-}

-- | General function used to implement all insert functions.
insertLookupGen :: CritBitKey k
                => (Maybe v -> CritBit k v -> a)
                -> (k -> v -> v -> v)
                -> k -> v -> CritBit k v -> a
insertLookupGen ret f !k v (CritBit root) = go root
  where
    go i@(Internal {..})
      | direction k i == 0 = go ileft
      | otherwise          = go iright
    go (Leaf lk v')
      | keyPresent = wrap (Just v')
      | otherwise  = wrap Nothing
        where
          keyPresent = k == lk
          wrap val = ret val . CritBit $ rewalk root

          rewalk i@(Internal {..})
            | ibyte > n          = finish i
            | ibyte == n && iotherBits > nob = finish i
            | direction k i == 0 = i { ileft = rewalk ileft }
            | otherwise          = i { iright = rewalk iright }
          rewalk i = finish i

          finish node
            | keyPresent = Leaf k (f k v v')
            | nd == 0    = Internal node (Leaf k v) n nob
            | otherwise  = Internal (Leaf k v) node n nob

          (n, nob, c) = followPrefixes k lk
          nd          = calcDirection nob c
    go Empty = ret Nothing . CritBit $ Leaf k v
{-# INLINE insertLookupGen #-}

lookupWith :: (CritBitKey k) =>
              a                 -- ^ Failure continuation
           -> (v -> a)          -- ^ Success continuation
           -> k
           -> CritBit k v -> a
-- We use continuations here to avoid reimplementing the lookup
-- algorithm with trivial variations.
lookupWith notFound found k (CritBit root) = go root
  where
    go i@(Internal {..})
       | direction k i == 0  = go ileft
       | otherwise           = go iright
    go (Leaf lk v) | k == lk = found v
    go _                     = notFound
{-# INLINE lookupWith #-}

-- | /O(log n)/. Lookup and update; see also 'updateWithKey'.
-- This function returns the changed value if it is updated, or
-- the original value if the entry is deleted.
--
-- > let f k x = if x == 5 then Just (x + fromEnum (k < "d")) else Nothing
-- > updateLookupWithKey f "a" (fromList [("b",3), ("a",5)]) == (Just 6, fromList [("a", 6), ("b",3)])
-- > updateLookupWithKey f "c" (fromList [("a",5), ("b",3)]) == (Nothing, fromList [("a",5), ("b",3)])
-- > updateLookupWithKey f "b" (fromList [("a",5), ("b",3)]) == (Just 3, singleton "a" 5)
updateLookupWithKey :: (CritBitKey k) => (k -> v -> Maybe v) -> k
                       -> CritBit k v -> (Maybe v, CritBit k v)
-- Once again with the continuations! It's somewhat faster to do
-- things this way than to expicitly unwind our recursion once we've
-- found the leaf to delete. It's also a ton less code.
--
-- (If you want a good little exercise, rewrite this function without
-- using continuations, and benchmark the two versions.)
updateLookupWithKey f k t@(CritBit root) = top root
  where
    top i@(Internal {..}) = go i ileft iright CritBit
    top (Leaf lk lv) | k == lk =
      maybeUpdate lk lv (\v -> CritBit $ Leaf lk v) (CritBit Empty)
    top _ = (Nothing, t)

    go i left right cont
      | direction k i == 0 =
        case left of
          i'@(Internal left' right' _ _) ->
            go i' left' right' $ \l -> cont $! i { ileft = l }
          Leaf lk lv -> maybeUpdate lk lv
                        (\v -> cont $! i { ileft = (Leaf lk v) })
                        (cont right)
          _ -> error "Data.CritBit.Core.updateLookupWithKey: Empty in tree."
      | otherwise =
        case right of
          i'@(Internal left' right' _ _) ->
            go i' left' right' $ \r -> cont $! i { iright = r }
          Leaf lk lv -> maybeUpdate lk lv
                        (\v -> cont $! i { iright = (Leaf lk v) })
                        (cont left)
          _ -> error "Data.CritBit.Core.updateLookupWithKey: Empty in tree."

    maybeUpdate lk lv c1 c2
      | k == lk = case f lk lv of
                    Just lv' -> (Just lv', c1 lv')
                    Nothing  -> (Just lv, c2)
      | otherwise = (Nothing, t)
    {-# INLINE maybeUpdate #-}

{-# INLINABLE updateLookupWithKey #-}

-- | Determine which direction we should move down the tree based on
-- the critical bitmask at the current node and the corresponding byte
-- in the key. Left is 0, right is 1.
direction :: (CritBitKey k) => k -> Node k v -> Int
direction k (Internal _ _ byte otherBits) =
    calcDirection otherBits (getByte k byte)
direction _ _ = error "Data.CritBit.Core.direction: unpossible!"
{-# INLINE direction #-}

-- Given a critical bitmask and a byte, return 0 to move left, 1 to
-- move right.
calcDirection :: BitMask -> Word16 -> Int
calcDirection otherBits c = (1 + fromIntegral (otherBits .|. c)) `shiftR` 9
{-# INLINE calcDirection #-}

-- | Figure out the byte offset at which the key we are interested in
-- differs from the leaf we reached when we initially walked the tree.
--
-- We return some auxiliary stuff that we'll bang on to help us figure
-- out which direction to go in to insert a new node.
followPrefixes :: (CritBitKey k) =>
                  k             -- ^ The key from "outside" the tree.
               -> k             -- ^ Key from the leaf we reached.
               -> (Int, BitMask, Word16)
followPrefixes = followPrefixesFrom 0
{-# INLINE followPrefixes #-}

-- | Figure out the offset of the first different byte in two keys,
-- starting from specified position.
--
-- We return some auxiliary stuff that we'll bang on to help us figure
-- out which direction to go in to insert a new node.
followPrefixesFrom :: (CritBitKey k) =>
                      Int           -- ^ Positition to start from
                   -> k             -- ^ First key.
                   -> k             -- ^ Second key.
                   -> (Int, BitMask, Word16)
followPrefixesFrom !position !k !l = (n, maskLowerBits (b `xor` c), c)
  where
    n = followPrefixesByteFrom position k l
    b = getByte k n
    c = getByte l n

    maskLowerBits :: Word16 -> Word16
    maskLowerBits v = (n3 .&. (complement (n3 `shiftR` 1))) `xor` 0x1FF
      where
        n3 = n2 .|. (n2 `shiftR` 8)
        n2 = n1 .|. (n1 `shiftR` 4)
        n1 = n0 .|. (n0 `shiftR` 2)
        n0 = v  .|. (v  `shiftR` 1)
{-# INLINE followPrefixesFrom #-}

-- | Figure out the offset of the first different byte in two keys,
-- starting from specified position.
followPrefixesByteFrom :: (CritBitKey k) =>
                          Int           -- ^ Positition to start from
                       -> k             -- ^ First key.
                       -> k             -- ^ Second key.
                       -> Int
followPrefixesByteFrom !position !k !l = go position
  where
    go !n | b /= c || b == 0 || c == 0 = n
          | otherwise                  = go (n + 1)
      where b = getByte k n
            c = getByte l n
{-# INLINE followPrefixesByteFrom #-}

leftmost, rightmost :: a -> (k -> v -> a) -> Node k v -> a
leftmost  = extremity ileft
{-# INLINE leftmost #-}
rightmost = extremity iright
{-# INLINE rightmost #-}

-- | Generic function so we can easily implement 'leftmost' and 'rightmost'.
extremity :: (Node k v -> Node k v) -- ^ Either 'ileft' or 'iright'.
          -> a                      -- ^ 'Empty' continuation.
          -> (k -> v -> a)          -- ^ 'Leaf' continuation.
          -> Node k v
          -> a
extremity direct onEmpty onLeaf node = go node
  where
    go i@(Internal{}) = go $ direct i
    go (Leaf k v)     = onLeaf k v
    go _              = onEmpty
    {-# INLINE go #-}
{-# INLINE extremity #-}
