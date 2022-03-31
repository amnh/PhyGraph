{- |
Module      :  Utilities.hs
Description :  Module specifying utility functions for use with PhyGraph
Copyright   :  (c) 2021 Ward C. Wheeler, Division of Invertebrate Zoology, AMNH. All rights reserved.
License     :

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

The views and conclusions contained in the software and documentation are those
of the authors and should not be interpreted as representing official policies,
either expressed or implied, of the FreeBSD Project.

Maintainer  :  Ward Wheeler <wheeler@amnh.org>
Stability   :  unstable
Portability :  portable (I hope)

-}

module Utilities.Utilities  where

import qualified Data.Vector as V
import           Data.Maybe
import qualified Data.List as L
import           Data.BitVector.LittleEndian (BitVector)
import qualified Data.BitVector.LittleEndian as BV
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import Data.Alphabet
import Data.Alphabet.Codec
import Data.Alphabet.IUPAC
-- import Data.Alphabet.Special
import Data.Foldable
import Data.Bits
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Bimap as BM
import Types.Types
import           Data.Text.Short (ShortText)
import qualified Data.Text.Short             as ST
import qualified GeneralUtilities as GU
import Debug.Trace
import qualified Utilities.LocalGraph as LG
import qualified Data.Text.Lazy  as T
import qualified Data.Vector.Storable        as SV
import qualified Data.Vector.Unboxed         as UV
import qualified SymMatrix                   as S
import GeneralUtilities

-- | getblockInsertDataCost gets teh total cost of 'inserting' the data in a block
getblockInsertDataCost :: BlockData -> Double
getblockInsertDataCost (_, characterDataVV, charInfoV) =
    V.sum $ fmap (getLeafInsertCost charInfoV) characterDataVV

-- | getLeafInsertCost is the cost or ortiginating or 'inserting' leaf data
-- for all characters in a block
getLeafInsertCost :: V.Vector CharInfo -> V.Vector CharacterData -> Double
getLeafInsertCost charInfoV charDataV = 
    V.sum $ V.zipWith getCharacterInsertCost charDataV charInfoV

-- | getCharacterInsertCost takes a character and characterInfo and returns origination/insert cost for the character
getCharacterInsertCost :: CharacterData -> CharInfo -> Double
getCharacterInsertCost inChar charInfo =
    let localCharType = charType charInfo
        thisWeight = weight charInfo
        inDelCost = (costMatrix charInfo) S.! (0, (length (alphabet charInfo) - 1))
    in
    if localCharType == Add then thisWeight * (fromIntegral $ V.length $ GU.fst3 $ rangePrelim inChar)
    else if localCharType == NonAdd then thisWeight * (fromIntegral $ V.length $ GU.fst3 $ stateBVPrelim inChar) 
    else if localCharType == Matrix then thisWeight * (fromIntegral $ V.length $ matrixStatesPrelim inChar)
    else if localCharType == SlimSeq || localCharType == NucSeq then thisWeight * (fromIntegral inDelCost) * (fromIntegral $ SV.length $ slimPrelim inChar)
    else if localCharType == WideSeq || localCharType ==  AminoSeq then thisWeight * (fromIntegral inDelCost) * (fromIntegral $ UV.length $ widePrelim inChar)
    else if localCharType == HugeSeq then thisWeight * (fromIntegral inDelCost) * (fromIntegral $ V.length $ hugePrelim inChar)
    else if localCharType == AlignedSlim then thisWeight * (fromIntegral inDelCost) * (fromIntegral $ SV.length $ snd3 $ alignedSlimPrelim inChar)
    else if localCharType == AlignedWide then thisWeight * (fromIntegral inDelCost) * (fromIntegral $ UV.length $ snd3 $ alignedWidePrelim inChar)
    else if localCharType == AlignedHuge then thisWeight * (fromIntegral inDelCost) * (fromIntegral $ V.length $ snd3 $ alignedHugePrelim inChar)
    else error ("Character type unimplemented : " ++ show localCharType)


-- | splitSequence takes a ShortText divider and splits a list of ShortText on 
-- that ShortText divider consuming it akin to Text.splitOn
splitSequence :: ST.ShortText -> [ST.ShortText] -> [[ST.ShortText]]
splitSequence partitionST stList =
    if null stList then []
    else
        let firstPart = takeWhile (/= partitionST) stList
            restList = dropWhile (/= partitionST) stList
        in
        if restList == [partitionST] then firstPart : [[ST.fromString "#"]]
        else if not $ null restList then firstPart : splitSequence partitionST (tail restList)
        else [firstPart]

-- See Bio.DynamicCharacter.decodeState for a better implementation for dynamic character elements
bitVectToCharState :: Bits b => Alphabet String -> b -> String
bitVectToCharState localAlphabet bitValue = L.intercalate "," $ foldr pollSymbol mempty indices 
  where
    indices = [ 0 .. len - 1 ]
    len = length vec
    vec = alphabetSymbols localAlphabet
    pollSymbol i polled
      | bitValue `testBit` i = (vec V.! i) : polled
      | otherwise         = polled


-- bitVectToCharState  takes a bit vector representation and returns a list states as integers
bitVectToCharState' :: (Bits b) => [String] -> b -> String
bitVectToCharState' localAlphabet bitValue
  | isAlphabetDna       hereAlphabet = fold $ iupacToDna       BM.!> observedSymbols
  | isAlphabetAminoAcid hereAlphabet = fold $ iupacToAminoAcid BM.!> observedSymbols
  | otherwise = L.intercalate "," $ toList observedSymbols
  where
      hereAlphabet = fromSymbols localAlphabet
      symbolCountH = length localAlphabet
      observedSymbols
        = NE.fromList
            $ foldMap
                (\ i -> [localAlphabet !! i | bitValue `testBit` i])
                [0 .. symbolCountH - 1]

-- | matrixStateToStringtakes a matrix state and returns a string representation
matrixStateToString :: V.Vector MatrixTriple -> String
matrixStateToString inStateVect =
    let minCost = V.minimum $ fmap fst3 inStateVect
        minCostStates = V.toList $ V.filter ((== minCost) . fst3) inStateVect
        statesStringList = fmap show minCostStates
    in
    if length statesStringList == 1 then head statesStringList
    else 
        "[" ++ (L.intercalate " " statesStringList) ++ "]"



-- | additivStateToString take an additive range and prints single state if range equal or 
-- [a-b] if not
additivStateToString :: (Int, Int) -> String
additivStateToString (a,b) = if a == b then show a
                             else "[" ++ (show a) ++ "-" ++ (show b) ++ "]"

-- | filledDataFields takes rawData and checks taxon to see what percent
-- "characters" are found.
-- call with (0,0)
filledDataFields :: (Int, Int) -> TermData -> (NameText, Int, Int)
filledDataFields (hasData, totalData) (taxName, taxData)
  | null taxData = (taxName, hasData, totalData)
  | ST.length (head taxData) == 0 = filledDataFields (hasData, 1 + totalData) (taxName, tail taxData)
  | otherwise = filledDataFields (1 + hasData, 1 + totalData) (taxName, tail taxData)

-- | stripComments removes all lines that being with "--" haskell stype comments
-- needs to be reversed on return to maintain order.
stripComments :: [String] -> [String]
stripComments inStringList =
    if null inStringList then []
    else
        let strippedLine = GU.stripString $ head inStringList
        in
        if null strippedLine then stripComments $ tail inStringList
        else if length strippedLine < 2 then strippedLine : stripComments (tail inStringList)
        else
            if "--" == take 2 strippedLine then stripComments $ tail inStringList
            else strippedLine : stripComments (tail inStringList)

-- | getDecoratedGraphBlockCharInformation takes decorated graph and reports number of blosk and size of each
getDecoratedGraphBlockCharInformation :: DecoratedGraph -> ((Int, Int), [V.Vector Int])
getDecoratedGraphBlockCharInformation inGraph =
    if LG.isEmpty inGraph then ((0,0), [])
    else
        -- get a vertices from graph and take their information
        let inVertDataList = fmap (vertData . snd) (LG.labNodes inGraph)
            blockNumMax = maximum $ fmap length inVertDataList
            blocknumMin = minimum $ fmap length inVertDataList
            blockLengthList = fmap (fmap length) inVertDataList
        in
        ((blockNumMax, blocknumMin), blockLengthList)

-- | vectMaybeHead takes a vector and returns JUst V.head if not V.empty
-- Nothing otherwise
vectMaybeHead :: V.Vector a -> Maybe a
vectMaybeHead inVect =
    if V.null inVect then Nothing
    else Just (V.head inVect)

-- vectResolveMaybe takes a Vector of Maybe a 
-- and returns Just a or V.empty
vectResolveMaybe :: V.Vector (Maybe a) -> V.Vector a
vectResolveMaybe inVect =
    trace ("VRM " ++ show (length inVect)) (
    if isNothing (V.head inVect) then V.empty
    else V.singleton $ fromJust $ V.head inVect
    )

-- | getNumberSequenceCharacters takes processed data and returns the number of non-exact (= sequen ce) characters
-- ised to special case datasets with limited non-exact characters
getNumberSequenceCharacters :: V.Vector BlockData -> Int
getNumberSequenceCharacters blockDataVect =
    if V.null blockDataVect then 0
    else
        let firstBlock = GU.thd3 $ V.head blockDataVect
            characterTypes = V.map charType firstBlock
            sequenceChars = length $ V.filter (== True) $ V.map (`elem` sequenceCharacterTypes) characterTypes
        in
        sequenceChars + getNumberSequenceCharacters (V.tail blockDataVect)

-- | getNumberExactCharacters takes processed data and returns the number of non-exact characters
-- ised to special case datasets with limited non-exact characters
getNumberExactCharacters :: V.Vector BlockData -> Int
getNumberExactCharacters blockDataVect =
    if V.null blockDataVect then 0
    else
        let firstBlock = GU.thd3 $ V.head blockDataVect
            characterTypes = V.map charType firstBlock
            exactChars = length $ V.filter (== True) $ V.map (`elem` exactCharacterTypes) characterTypes
        in
        exactChars + getNumberExactCharacters (V.tail blockDataVect)

-- | splitBlockCharacters takes a block of characters (vector) and splits into two partitions of exact (Add, NonAdd, Matrix) and sequence characters
-- (= nonExact) using accumulators
splitBlockCharacters :: V.Vector (V.Vector CharacterData)
                     -> V.Vector CharInfo
                     -> Int
                     -> [([CharacterData], CharInfo)]
                     -> [([CharacterData], CharInfo)]
                     -> (BlockData, BlockData)
splitBlockCharacters inDataVV inCharInfoV localIndex exactCharPairList seqCharPairList =
    if localIndex == V.length inCharInfoV then
        let (exactDataList, exactCharInfoList) = unzip exactCharPairList
            (sequenceDataList, sequenceCharInfoList) = unzip seqCharPairList
            newExactCharInfoVect = V.fromList $ reverse exactCharInfoList
            newSeqCharCharInfoVect = V.fromList $ reverse sequenceCharInfoList
            newExactData = V.fromList $ fmap (V.fromList . reverse) (L.transpose exactDataList)
            newSeqCharData = V.fromList $ fmap (V.fromList . reverse) (L.transpose sequenceDataList)
        in
        ((T.pack "ExactCharacters", newExactData, newExactCharInfoVect), (T.pack "Non-ExactCharacters", newSeqCharData, newSeqCharCharInfoVect))
    else
        let localCharacterType = charType (inCharInfoV V.! localIndex)
            thisCharacterData = V.toList $ fmap (V.! localIndex) inDataVV
            newPair = (thisCharacterData, inCharInfoV V.! localIndex)
        in
        if localCharacterType `elem` exactCharacterTypes then
            splitBlockCharacters inDataVV inCharInfoV (localIndex + 1) (newPair : exactCharPairList) seqCharPairList
        else if localCharacterType `elem` sequenceCharacterTypes then
            splitBlockCharacters inDataVV inCharInfoV (localIndex + 1) exactCharPairList (newPair : seqCharPairList)
        else error ("Unrecongized/implemented character type: " ++ show localCharacterType)



-- | safeVectorHead safe vector head--throws error if null
safeVectorHead :: V.Vector a -> a
safeVectorHead inVect =
    if V.null inVect then error "Empty vector in safeVectorHead"
    else V.head inVect

-- | get leftRightChilLabelBV takes a pair of vertex labels and returns left and right
-- based on their bitvector representation.  This ensures left/right consistancey in
-- pre and postoder passes, and with bitvectors of leaves determined by data hash,
-- ensures label invariance with repect to leaves 
-- larger bitvector goes second (bigge)
leftRightChildLabelBV :: (VertexInfo, VertexInfo) -> (VertexInfo, VertexInfo)
leftRightChildLabelBV inPair@(firstNode, secondNode) =
    let firstLabel  = bvLabel firstNode
        secondLabel = bvLabel secondNode
    in
    if firstLabel > secondLabel then (secondNode, firstNode)
    else inPair

-- | get leftRightChildLabelBVNode takes a pair ofnodes and returns left and right
-- based on their bitvector representation.  This ensures left/right consistancey in
-- pre and postoder passes, and with bitvectors of leaves determined by data hash,
-- ensures label invariance with repect to leaves 
-- larger bitvector goes second (bigge)
leftRightChildLabelBVNode :: (LG.LNode VertexInfo, LG.LNode VertexInfo) -> (LG.LNode VertexInfo, LG.LNode VertexInfo)
leftRightChildLabelBVNode inPair@(firstNode, secondNode) =
    let firstLabel  = bvLabel $ snd firstNode
        secondLabel = bvLabel $ snd secondNode
    in
    if firstLabel > secondLabel then (secondNode, firstNode)
    else inPair


-- | prettyPrintVertexInfo returns a string with formated version of 
-- vertex info
prettyPrintVertexInfo :: VertexInfo -> String
prettyPrintVertexInfo inVertData =
    let zerothPart = "Vertex name " ++ T.unpack (vertName inVertData) ++ " Index " ++ show (index inVertData)
        firstPart = "\n\tBitVector (as number) " ++ show (BV.toUnsignedNumber $ bvLabel inVertData)
        secondPart = "\n\tParents " ++ show (parents inVertData) ++ " Children " ++ show (children inVertData)
        thirdPart = "\n\tType " ++ show (nodeType inVertData) ++ " Local Cost " ++ show (vertexCost inVertData) ++ " SubGraph Cost " ++ show (subGraphCost inVertData)
        fourthPart = "\n\tData Blocks: " ++ show (V.length $ vertData inVertData) ++ " Characters (by block) " ++ show (V.length <$> vertData inVertData)
        fifthPart = "\n\t" ++ show (vertData inVertData)
    in
    zerothPart ++ firstPart ++ secondPart ++ thirdPart ++ fourthPart ++ fifthPart


-- | add3 adds three values
add3 :: (Num a) => a -> a -> a -> a
add3 x y z = x + y + z

-- | getProcessDataByBlock takes ProcessData and returns a list of Processed data with one block 
-- per processed data element
-- argument to filter terminals with missing taxa
-- wraps around getProcessDataByBlock' with counter
getProcessDataByBlock :: Bool -> ProcessedData -> [ProcessedData] 
getProcessDataByBlock filterMissing (nameVect, nameBVVect, blockDataVect) = reverse $ getProcessDataByBlock' filterMissing 0 (nameVect, nameBVVect, blockDataVect)


-- | getProcessDataByBlock' called by getProcessDataByBlock with counter
-- and later reversed
getProcessDataByBlock' :: Bool -> Int -> ProcessedData -> [ProcessedData] 
getProcessDataByBlock' filterMissing counter (nameVect, nameBVVect, blockDataVect) = 
    if V.null blockDataVect then []
    else if counter == (V.length blockDataVect) then []
    else 
        let thisBlockData = blockDataVect V.! counter
        in
        if not filterMissing then (nameVect, nameBVVect, V.singleton thisBlockData) : getProcessDataByBlock' filterMissing (counter + 1) (nameVect, nameBVVect, blockDataVect)
        else 
            let (blockName, charDataLeafVect, blockCharInfo) = thisBlockData
                isMissingVect = V.map V.null charDataLeafVect
                (nonMissingNameVect, nonMissingBVVect, nonMissingLeafData, _) = V.unzip4 $ V.filter ((== False) . GU.fth4) (V.zip4 nameVect nameBVVect charDataLeafVect isMissingVect)
                nonMissingBlockData = (blockName, nonMissingLeafData, blockCharInfo)
            in
            (nonMissingNameVect, nonMissingBVVect, V.singleton nonMissingBlockData) : getProcessDataByBlock' filterMissing (counter + 1) (nameVect, nameBVVect, blockDataVect) 


-- | copyToNothing takes VertexBlockData and copies to VertexBlockDataMaybe
-- data as nothing
copyToNothing :: VertexBlockData -> VertexBlockDataMaybe
copyToNothing vbd = fmap setNothing vbd
    where setNothing a = V.replicate (V.length a) Nothing


-- | copyToJust takes VertexBlockData and copies to VertexBlockDataMaybe
-- data as Just CharacterData
copyToJust :: VertexBlockData -> VertexBlockDataMaybe
copyToJust vbd = fmap (fmap Just) vbd

-- | simAnnealAccept takes simulated annealing parameters, current best graph (e) cost, 
-- candidate graph cost (e') and a uniform random integer and returns a Bool to accept or reject
-- the candidate solution
-- the basic method is 
--  1) accepts if current is better
--  2) Other wise prob accept = exp(-(e' -e)/T)
-- where T is a step from max to min 
-- maxT and minT can probbaly be set to 100 and 1 or something but leaving some flexibility
-- curStep == 0 random walk (always accept)
-- curStep == (numSteps -1) greedy False is not better
simAnnealAccept :: Maybe SAParams -> VertexCost -> VertexCost -> (Bool, Maybe SAParams)
simAnnealAccept inParams curBestCost candCost  =
    if inParams == Nothing then error "simAnnealAccept Simulated anneling parameters = Nothing"
    
    -- drifting probs
    else if (method $ fromJust inParams) == Drift then
        driftAccept inParams curBestCost candCost

    -- simulated annealing probs
    else 
        let simAnealVals =  fromJust inParams
            numSteps = numberSteps simAnealVals
            curStep  = currentStep simAnealVals
            randIntList = randomIntegerList simAnealVals

            stepFactor =  (fromIntegral $ numSteps - curStep) / (fromIntegral numSteps)
            tempFactor = curBestCost  * stepFactor 

            candCost' = if curBestCost == candCost then candCost + 1
                        else candCost
                    -- flipped order - (e' -e)
            -- probAcceptance = exp ((curBestCost - candCost) / ((maxTemp - minTemp) * tempFactor))
            probAcceptance = exp ( (fromIntegral (curStep + 1)) * (curBestCost - candCost') / tempFactor)

            -- multiplier for resolution 1000, 100 prob be ok
            randMultiplier = 1000
            intAccept = floor $ (fromIntegral randMultiplier) * probAcceptance

            -- use remainder for testing--passing infinite list and take head
            (_, intRandVal) = divMod (abs $ head randIntList) randMultiplier

            nextSAParams = Just $ (fromJust inParams) {currentStep = curStep + 1, randomIntegerList = tail randIntList}
        in
        -- lowest cost-- greedy
        -- trace ("RA " ++ (show intAccept)) (
        if candCost < curBestCost then 
                --trace ("SAB: " ++ (show curStep) ++ " True") 
                (True, nextSAParams)

        -- not better and at lowest temp
        else if curStep >= (numSteps - 1) then
                -- trace ("SAEnd: " ++ (show curStep) ++ " False") 
                (False, nextSAParams)
        
        -- test for non-lowest temp conditions
        else if intRandVal < intAccept then 
                -- trace ("SAAccept: " ++ (show (curStep, candCost, curBestCost, tempFactor, probAcceptance, intAccept, intRandVal)) ++ " True") 
                (True, nextSAParams)
        else 
                -- trace ("SAReject: " ++ (show (curStep, candCost, curBestCost, tempFactor, probAcceptance, intAccept, intRandVal)) ++ " False") 
                (False, nextSAParams)
        -- )

-- | incrementSimAnnealParams increments the step number by 1 but returns all other the same
incrementSimAnnealParams :: Maybe SAParams -> Maybe SAParams
incrementSimAnnealParams inParams =
    if inParams == Nothing then error "incrementSimAnnealParams Simulated anneling parameters = Nothing"
    else 
        let curStep = currentStep $ fromJust inParams
            curChanges = driftChanges $ fromJust inParams
            randList = tail $ randomIntegerList $ fromJust inParams
        in

        -- simulated annelaing temperature step
        if method (fromJust inParams) == SimAnneal then 
            Just $ (fromJust inParams) { currentStep = curStep + 1
                                       , randomIntegerList = randList
                                       }
        -- drifting change number
        else 
            Just $ (fromJust inParams) { driftChanges = curChanges + 1
                                       , randomIntegerList = randList
                                       }

-- | generateUniqueRandList take a int and simulated anealing parameter slist and creates 
-- a list of SA paramter values with unique rnandomInt lists
-- sets current step to 0
generateUniqueRandList :: Int -> Maybe SAParams -> [Maybe SAParams]
generateUniqueRandList number inParams =
    if number == 0 then []
    else if inParams == Nothing then replicate number Nothing
    else 
        let randIntList = randomIntegerList $ fromJust inParams  
            randSeedList = take number randIntList
            randIntListList = fmap GU.randomIntList randSeedList
            -- simAnnealParamList = replicate number inParams
            newSimAnnealParamList = fmap Just $ fmap (updateSAParams (fromJust inParams)) randIntListList 
        in
        -- trace (show $ fmap (take 1) randIntListList)
        newSimAnnealParamList

        where updateSAParams a b = a {randomIntegerList = b}

-- | driftAccept takes SAParams, currrent best cost, and cadidate cost
-- and returns a Boolean and an incremented set of params
driftAccept :: Maybe SAParams -> VertexCost -> VertexCost -> (Bool, Maybe SAParams)
driftAccept simAnealVals curBestCost candCost  =
    if simAnealVals == Nothing then error "Nothing value in driftAccept"
    else 
        let curNumChanges = driftChanges $ fromJust simAnealVals
            randIntList = randomIntegerList $ fromJust simAnealVals

            --- prob acceptance for better, same, and worse costs
            probAcceptance = if candCost < curBestCost then 1.0
                             else if candCost == curBestCost then driftAcceptEqual $ fromJust simAnealVals
                             else 1.0 / ((driftAcceptWorse $ fromJust simAnealVals) + candCost - curBestCost)

            -- multiplier for resolution 1000, 100 prob be ok
            randMultiplier = 1000
            intAccept = floor $ (fromIntegral randMultiplier) * probAcceptance

            -- use remainder for testing--passing infinite list and take head
            (_, intRandVal) = divMod (abs $ head randIntList) randMultiplier

            -- not always incrementing becasue may not result in changes
            nextSAParams = Just $ (fromJust simAnealVals) {driftChanges = curNumChanges + 1, randomIntegerList = tail randIntList}
            nextSAPAramsNoChange = Just $ (fromJust simAnealVals) {randomIntegerList = tail randIntList}
        
        in
        -- only increment nnumberof changes for True values
        if candCost < curBestCost then 
            -- trace ("Drift B: " ++ (show (curNumChanges, candCost, curBestCost, probAcceptance, intAccept, intRandVal)) ++ " True")
            (True, nextSAParams)

        else if intRandVal < intAccept then 
            -- trace ("Drift T: " ++ (show (curNumChanges, candCost, curBestCost, probAcceptance, intAccept, intRandVal)) ++ " True")
            (True, nextSAParams)

        else 
            -- trace ("Drift F: " ++ (show (curNumChanges, candCost, curBestCost, probAcceptance, intAccept, intRandVal)) ++ " False") 
            (False, nextSAPAramsNoChange)
            -- )


-- | getTraversalCosts takes a Phylogenetic Graph and returns costs of traversal trees
getTraversalCosts :: PhylogeneticGraph -> [VertexCost]
getTraversalCosts inGraph =
    let traversalTrees = V.toList $ fmap V.toList $ fft6 inGraph
        traversalRoots = fmap head $ fmap LG.getRoots $ concat traversalTrees
        traversalRootCosts = fmap (subGraphCost . snd) traversalRoots
    in
    traversalRootCosts


-- | getCharacterLengths returns a the length of block characters
getCharacterLength :: CharacterData -> CharInfo -> Int
getCharacterLength inCharData inCharInfo = 
    let inCharType = charType inCharInfo
    in
    -- trace ("GCL:" ++ (show inCharType) ++ " " ++ (show $ snd3 $ stateBVPrelim inCharData)) (
    case inCharType of
      x | x `elem` [NonAdd           ] -> V.length  $ snd3 $ stateBVPrelim inCharData
      x | x `elem` [Add              ] -> V.length  $ snd3 $ rangePrelim inCharData
      x | x `elem` [Matrix           ] -> V.length  $ matrixStatesPrelim inCharData
      x | x `elem` [SlimSeq, NucSeq  ] -> SV.length $ snd3 $ slimAlignment inCharData
      x | x `elem` [WideSeq, AminoSeq] -> UV.length $ snd3 $ wideAlignment inCharData
      x | x `elem` [HugeSeq]           -> V.length  $ snd3 $ hugeAlignment inCharData
      x | x `elem` [AlignedSlim]       -> SV.length $ snd3 $ alignedSlimPrelim inCharData
      x | x `elem` [AlignedWide]       -> UV.length $ snd3 $ alignedWidePrelim inCharData
      x | x `elem` [AlignedHuge]       -> V.length  $ snd3 $ alignedHugePrelim inCharData 
      _                                -> error ("Un-implemented data type " ++ show inCharType)
      -- )

-- | getCharacterLengths' flipped arg version of getCharacterLength
getCharacterLength' :: CharInfo -> CharacterData -> Int
getCharacterLength' inCharInfo inCharData = getCharacterLength inCharData inCharInfo

-- | getMaxCharacterLengths get maximum charcter legnth from a list
getMaxCharacterLength :: CharInfo -> [CharacterData] -> Int
getMaxCharacterLength inCharInfo inCharDataList = maximum $ fmap (getCharacterLength' inCharInfo) inCharDataList 


-- | getSingleTaxon takes a taxa x characters block and an index and returns the character vector for that index
getSingleTaxon :: V.Vector (V.Vector CharacterData) -> Int -> V.Vector CharacterData
getSingleTaxon singleCharVect taxonIndex = fmap (V.! taxonIndex) singleCharVect

-- | glueBackTaxChar takes single chartacter taxon vectors and glues them back inot multiple characters for each 
-- taxon as expected in Blockdata.  Like a transpose.  FIlters out zero length characters
glueBackTaxChar :: V.Vector (V.Vector CharacterData) -> V.Vector (V.Vector CharacterData)
glueBackTaxChar singleCharVect =
    let numTaxa = V.length $ V.head singleCharVect
        multiCharVect =  fmap (getSingleTaxon singleCharVect) (V.fromList [0.. numTaxa - 1])
    in
    multiCharVect

-- | getSingleCharacter takes a taxa x characters block and an index and returns the character vector for that index
-- resulting in a taxon by single charcater vector 
getSingleCharacter :: V.Vector (V.Vector CharacterData) -> Int -> V.Vector CharacterData
getSingleCharacter taxVectByCharVect charIndex = fmap (V.! charIndex) taxVectByCharVect

