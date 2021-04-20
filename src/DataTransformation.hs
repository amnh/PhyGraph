{- |
Module      :  DataTransformation.hs
Description :  Module with functionality to transform phylogenetic data
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


module DataTransformation ( renameData
                          , getDataTerminalNames
                          , addMissingTerminalsToInput
                          , checkDuplicatedTerminals
                          , createNaiveData
                          , createBVNames
                          ) where


import qualified Data.Text.Lazy as T
import           Types
import           Data.List
import           Data.Maybe
import qualified Data.BitVector as BV
import qualified Data.Vector    as V
import qualified Data.Text.Short as ST
import qualified Data.Hashable as H
import           Debug.Trace

-- | renameData takes a list of rename Text pairs (new name, oldName)
-- and replaces the old name with the new
renameData :: [(T.Text, T.Text)] -> RawData -> RawData
renameData newNamePairList inData =
  if null newNamePairList then inData
  else
      let terminalData =  fst inData
      in
      if null terminalData then inData
      else 
          let newTerminalData = fmap (relabelterminalData newNamePairList) terminalData
          in
          (newTerminalData, snd inData)

-- | relabelterminalData takes a list of Text pairs and the terminals with the
-- second name in the pairs is changed to the first
relabelterminalData :: [(T.Text, T.Text)] -> TermData -> TermData
relabelterminalData namePairList terminalData@(leafName, leafData) = 
     if null namePairList then terminalData
     else 
        let foundName = find ((== leafName) .snd) namePairList 
        in
        if foundName == Nothing then terminalData
        else (fst $ fromJust foundName, leafData)

-- | getDataTerminalNames takes all input data and getss full terminal list
-- and adds missing data for trerminals not in input files 
getDataTerminalNames :: [RawData] -> [T.Text]
getDataTerminalNames inDataList =
    if null inDataList then []
    else 
        sort $ nub $ fmap fst $ concat $ fmap fst inDataList

-- | addMissingTerminalsToInput dataLeafNames renamedData 
addMissingTerminalsToInput :: [T.Text] -> RawData -> RawData
addMissingTerminalsToInput dataLeafNames inData@(termDataList, charInfoList) = 
    if null dataLeafNames then (sortOn fst termDataList, charInfoList)
    else 
        let firstLeafName = head dataLeafNames
            foundLeaf = find ((== firstLeafName) .fst)  termDataList
        in
        if foundLeaf /= Nothing then addMissingTerminalsToInput (tail dataLeafNames) inData
        else addMissingTerminalsToInput (tail dataLeafNames) ((firstLeafName, []) : termDataList, charInfoList)

-- | checkDuplicatedTerminals takes list TermData and checks for repeated terminal names
checkDuplicatedTerminals :: [TermData] -> (Bool, [T.Text]) 
checkDuplicatedTerminals inData =
    if null inData then (False, []) 
    else 
        let nameList = group $ sort $ fmap fst inData
            dupList = filter ((>1).length) nameList
        in
        if null dupList then (False, [])
        else (True, fmap head dupList)

-- | joinSortFileData takes list if list of short text and merges line by line to joing leaf states
-- and sorts the result
joinSortFileData :: [[ST.ShortText]] -> [String]
joinSortFileData inFileLists =
    if ((length $ head inFileLists) == 0) then []
    else     
        let firstLeaf = sort $ ST.toString $ ST.concat $ fmap head inFileLists
        in
        firstLeaf : joinSortFileData (fmap tail inFileLists)


-- | createBVNames takes input data, sorts the raw data, hashes, sorts those to create
-- unique, label invariant (but data related so arbitrary but consistent)
-- Assumes the rawData come in sorted by the data reconciliation process
-- These used for vertex labels, caching, left/right DO issues
createBVNames :: [RawData] -> [(T.Text, BV.BV)]
createBVNames inDataList =
    let rawDataList = fmap fst inDataList
        textNameList = fmap fst $ head rawDataList
        textNameList' = fmap fst $ last rawDataList
        fileLeafCharList = fmap (fmap snd) rawDataList
        fileLeafList =  fmap (fmap ST.concat) fileLeafCharList
        leafList = reverse $ joinSortFileData fileLeafList
        leafHash = fmap H.hash leafList 
        leafHashPair = sortOn fst $ zip leafHash textNameList
        (_, leafReoderedList) = unzip leafHashPair
        leafOrder = sortOn fst $ zip leafReoderedList [0..((length textNameList) - 1)]
        (nameList, intList) = unzip leafOrder
        bv1 = BV.bitVec (length nameList) (1 :: Integer)
        bvList = fmap (bv1 BV.<<.) (fmap (BV.bitVec (length nameList)) intList)
    in
    if textNameList /= textNameList' then error "Taxa are not properly ordered in createBVNames"
    else zip nameList bvList

-- | createNaiveData takes input RawData and transforms to "Naive" data.
-- these data are otganized into bloicks (set to input filenames initially)
-- and are bitvector coded, but are not organized by charcter type, packed ot
-- optimized in any other way (prealigned-> nonadd, Sankoff.  2 state sankoff to binary, 
-- constant charcaters skipped etc)
-- these processes take place latet
-- these data can be input to any data optimization commands and are useful
-- for data output as they haven't been reordered or transformed in any way.
-- the RawData is a list since it is organized by input file
-- the list accumulator is to avoid Vector snoc/cons O(n)
createNaiveData :: [RawData] -> [(T.Text, BV.BV)] -> [BlockData] -> ProcessedData
createNaiveData inDataList leafBitVectorNames curBlockData = 
    if null inDataList then (V.fromList $ fmap fst leafBitVectorNames, V.fromList $ reverse curBlockData)
    else 
        let firstInput@(firstData, firstCharInfo) = head inDataList
        in
        -- empty file should have been caught earlier, but avoids some head/tail errors
        if null firstCharInfo then createNaiveData (tail inDataList) leafBitVectorNames  curBlockData
        else 
            -- process data as come in--each of these should be from a single file
            -- and initially assigned to a single, unique block
            let thisBlockName = T.takeWhile (/= ':') $ name $ head firstCharInfo
                thisBlockCharInfo = V.fromList firstCharInfo
                recodedCharacters = recodeRawData (fmap snd firstData) firstCharInfo []
                thisBlockGuts = V.zip (V.fromList $ fmap snd leafBitVectorNames) recodedCharacters
                thisBlockData = (thisBlockName, thisBlockGuts, thisBlockCharInfo)
            in
            trace ("Recoding block: " ++ T.unpack thisBlockName)
            createNaiveData (tail inDataList) leafBitVectorNames  (thisBlockData : curBlockData)

-- | recodeRawData takes the ShortText representation of character states/ranges etc
-- and recodes the apporpriate fields in CharacterData (from Types) 
-- the list accumulator is to avoid Vectotr cons/snoc O(n)
-- differentiates between seqeunce type and others with char info
recodeRawData :: [[ST.ShortText]] -> [CharInfo] -> [[CharacterData]] -> V.Vector (V.Vector CharacterData)
recodeRawData inData inCharInfo curCharData =
    if null inData then V.fromList $ reverse $ fmap V.fromList curCharData
    else 
        let firstData = head inData
            firstDataRecoded = createLeafCharacter inCharInfo firstData
        in
        --trace ((show $ length inData) ++ " " ++ (show $ length firstData) ++ " " ++ (show $ length inCharInfo))
        recodeRawData (tail inData) inCharInfo (firstDataRecoded : curCharData)  

-- | missingNonAdditive is non-additive missing character value, all 1's based on alohabte size
missingNonAdditive :: CharInfo -> CharacterData
missingNonAdditive inCharInfo =
  let missingValue = CharacterData {    stateBVPrelim = V.singleton (BV.ones $ length $ alphabet inCharInfo)
                                      , minRangePrelim = V.empty
                                      , maxRangePrelim = V.empty
                                      , matrixStatesPrelim = V.empty
                                      , stateBVFinal = V.singleton (BV.ones $ length $ alphabet inCharInfo)
                                      , minRangeFinal = V.empty
                                      , maxRangeFinal = V.empty
                                      , matrixStatesFinal = V.empty
                                      , approxMatrixCost = V.singleton 0
                                      , localCostVect = V.singleton 0
                                      , localCost = 0.0
                                      , globalCost = 0.0
                                      }
  in missingValue

-- | missingAdditive is additive missing character value, all 1's based on alohabte size
missingAdditive :: CharInfo -> CharacterData
missingAdditive inCharInfo =
  let missingValue = CharacterData {    stateBVPrelim = V.empty
                                      , minRangePrelim = V.singleton (read (ST.toString $ head $ alphabet inCharInfo) :: Int)
                                      , maxRangePrelim = V.singleton (read (ST.toString $ last $ alphabet inCharInfo) :: Int)
                                      , matrixStatesPrelim = V.empty
                                      , stateBVFinal = V.empty
                                      , minRangeFinal = V.singleton (read (ST.toString $ head $ alphabet inCharInfo) :: Int)
                                      , maxRangeFinal = V.singleton (read (ST.toString $ last $ alphabet inCharInfo) :: Int)
                                      , matrixStatesFinal = V.empty
                                      , approxMatrixCost = V.singleton 0
                                      , localCostVect = V.singleton 0
                                      , localCost = 0.0
                                      , globalCost = 0.0
                                      }
  in missingValue

-- | missingMatrix is additive missing character value, all 1's based on alohabte size
missingMatrix :: CharInfo -> CharacterData
missingMatrix inCharInfo =
  let numStates = length $ alphabet inCharInfo
      missingState = (0 :: StateCost , -1 :: ChildIndex ,-1 :: ChildIndex)
      missingValue = CharacterData  { stateBVPrelim = V.empty
                                    , minRangePrelim = V.empty
                                    , maxRangePrelim = V.empty
                                    , matrixStatesPrelim = V.singleton (V.replicate numStates missingState)
                                    , stateBVFinal = V.empty
                                    , minRangeFinal = V.empty
                                    , maxRangeFinal = V.empty
                                    , matrixStatesFinal = V.singleton (V.empty)
                                    , approxMatrixCost = V.singleton 0
                                    , localCostVect = V.singleton 0
                                    , localCost = 0.0
                                    , globalCost = 0.0
                                    }
  in missingValue

-- | getMissingValue takes the charcater type ans returns the appropriate missineg data value
getMissingValue :: [CharInfo] -> [CharacterData] 
getMissingValue inChar
  | null inChar = []
  | (charType $ head inChar) `elem` [SmallAlphSeq, NucSeq, AminoSeq, GenSeq] = [] 
  | (charType $ head inChar) == NonAdd = (missingNonAdditive  $ head inChar) : getMissingValue (tail inChar)
  | (charType $ head inChar) == Add = (missingAdditive  $ head inChar) : getMissingValue (tail inChar)
  | (charType $ head inChar) == Matrix = (missingMatrix  $ head inChar) : getMissingValue (tail inChar)
  | otherwise= error ("Datatype " ++ (show $ charType $ head inChar) ++ " not recognized")


-- | getStateBitVectorList takes teh alphabet of a character ([ShorText])
-- and returns bitvectors (with of size alphabet) for each state in order of states in alphabet
getStateBitVectorList :: [ST.ShortText] -> V.Vector (ST.ShortText, BV.BV)
getStateBitVectorList localStates =
    if null localStates then error "Character with empty alphabet in getStateBitVectorList"
    else 
        let stateIndexList = [0..((length localStates) - 1)]
            bv1 = BV.bitVec (length localStates) (1 :: Integer)
            bvList = fmap (bv1 BV.<<.) (fmap (BV.bitVec (length localStates)) stateIndexList)
        in
        V.fromList $ zip localStates bvList

-- | getNucleotideSequenceChar returns the character sgtructure for a Nucleic Acid sequence type
getNucleotideSequenceCodes :: [ST.ShortText]-> V.Vector (ST.ShortText, BV.BV)
getNucleotideSequenceCodes localAlphabet  =
    let stateBVList = getStateBitVectorList localAlphabet
        stateA = snd $ stateBVList V.! 0
        stateC = snd $ stateBVList V.! 1
        stateG = snd $ stateBVList V.! 2
        stateT = snd $ stateBVList V.! 3
        stateGap = snd $ stateBVList V.! 4
        -- ambiguity codes
        pairR = (ST.singleton 'R', BV.or [stateA, stateG])
        pairY = (ST.singleton 'Y', BV.or [stateC, stateT])
        pairW = (ST.singleton 'W', BV.or [stateA, stateT])
        pairS = (ST.singleton 'S', BV.or [stateC, stateG])
        pairM = (ST.singleton 'M', BV.or [stateA, stateC])
        pairK = (ST.singleton 'K', BV.or [stateG, stateT])
        pairB = (ST.singleton 'B', BV.or [stateC, stateG, stateT])
        pairD = (ST.singleton 'D', BV.or [stateA, stateG, stateT])
        pairH = (ST.singleton 'H', BV.or [stateA, stateC, stateT])
        pairV = (ST.singleton 'V', BV.or [stateA, stateC, stateG])
        pairN = (ST.singleton 'N', BV.or [stateA, stateC, stateG, stateT])
        pairQuest = (ST.singleton '?', BV.or [stateA, stateC, stateG, stateT, stateGap])
        ambigPairVect = V.fromList $ [pairR, pairY, pairW, pairS, pairM, pairK, pairB, pairD, pairH, pairV, pairN, pairQuest]
        totalStateList = stateBVList V.++ ambigPairVect
    in
    --trace (show $ fmap BV.showBin $ fmap snd $ totalStateList)
    totalStateList

-- | nucleotideBVPairs for recoding DNA sequences
-- this done to insure not recalculating everything for each base
nucleotideBVPairs :: V.Vector (ST.ShortText, BV.BV)
nucleotideBVPairs = getNucleotideSequenceCodes (fmap ST.fromString ["A","C","G","T","-"]) 


-- | getAminoAcidSequenceCodes returns the character sgtructure for an Amino Acid sequence type
getAminoAcidSequenceCodes :: [ST.ShortText]-> V.Vector (ST.ShortText, BV.BV)
getAminoAcidSequenceCodes localAlphabet  =
    let stateBVList = getStateBitVectorList localAlphabet
        pairB = (ST.singleton 'B', BV.or [snd $ stateBVList V.! 2, snd $ stateBVList V.! 11]) -- B = D or N
        pairZ = (ST.singleton 'Z', BV.or [snd $ stateBVList V.! 3, snd $ stateBVList V.! 13]) -- E or Q
        pairX = (ST.singleton 'X', BV.or $ V.toList $ V.map snd (V.init stateBVList))  --All AA not '-'
        pairQuest = (ST.singleton '?', BV.or $ V.toList $ V.map snd stateBVList)       -- all including -'-' Not IUPAC
        ambigPairVect = V.fromList $ [pairB, pairZ, pairX, pairQuest]
        totalStateList = stateBVList V.++ ambigPairVect

    in
    --trace (show $ fmap BV.showBin $ fmap snd $ totalStateList)
    totalStateList


-- | aminoAcidBVPairs for recoding protein sequences
-- this done to insure not recalculating everything for each residue
-- B, Z, X, ? for ambiguities
aminoAcidBVPairs :: V.Vector (ST.ShortText, BV.BV)
aminoAcidBVPairs = getAminoAcidSequenceCodes (fmap ST.fromString ["A","C","D","E","F","G","H","I","K","L","M","N","P","Q","R","S","T","V","W","Y", "-"])

-- | getBVCode take a Vector of (ShortText, BV) and returns bitvector code for
-- ShortText state
getBVCode :: V.Vector (ST.ShortText, BV.BV) -> ST.ShortText -> BV.BV
getBVCode bvCodeVect inState = 
    let newCode = V.find ((== inState).fst) bvCodeVect
    in
    if newCode == Nothing then error ("State " ++ (ST.toString inState) ++ " not found in bitvect code " ++ show bvCodeVect)
    else snd $ fromJust newCode


-- | getSequenceChar takes shortext list and converts to a Vector of bit vector coded states
-- in a CharacterData structure
getSequenceChar :: V.Vector (ST.ShortText, BV.BV) -> [ST.ShortText] -> [CharacterData]
getSequenceChar nucBVPairVect stateList =
    if null stateList then error "Empty stateLIst in getNucleotideSequenceChar"
    else 
        let sequenceVect = V.fromList $ fmap (getBVCode nucBVPairVect) stateList
            newSequenceChar = CharacterData  {  stateBVPrelim = sequenceVect
                                              , minRangePrelim = V.empty
                                              , maxRangePrelim = V.empty
                                              , matrixStatesPrelim = V.empty
                                              , stateBVFinal = sequenceVect
                                              , minRangeFinal = V.empty
                                              , maxRangeFinal = V.empty
                                              , matrixStatesFinal = V.empty
                                              , approxMatrixCost = V.singleton 0
                                              , localCostVect = V.singleton 0
                                              , localCost = 0.0
                                              , globalCost = 0.0
                                              }
        in
        [newSequenceChar]

-- | getGeneralBVCode take a Vector of (ShortText, BV) and returns bitvector code for
-- ShortText state.  These states can be ambiguous as in general sequences
-- so states need to be parsed first
getGeneralBVCode :: V.Vector (ST.ShortText, BV.BV) -> ST.ShortText -> BV.BV
getGeneralBVCode bvCodeVect inState = 
    let inStateString = ST.toString inState
    in
    if '[' `notElem` inStateString then --single state
        let newCode = V.find ((== inState).fst) bvCodeVect
        in
        if newCode == Nothing then error ("State " ++ (ST.toString inState) ++ " not found in bitvect code " ++ show bvCodeVect)
        else snd $ fromJust newCode
    else 
        let statesStringList = words $ tail $ init inStateString
            stateList = fmap ST.fromString statesStringList
            maybeBVList =  fmap getBV stateList
            stateBVList = fmap snd $ fmap fromJust maybeBVList
            ambiguousBVState = BV.or stateBVList
        in
        if Nothing `elem` maybeBVList then error ("Ambiguity grooup " ++ inStateString ++ " contained states not found in bitvect code " ++ show bvCodeVect)
        else ambiguousBVState
            where getBV s = (V.find ((== s).fst)) bvCodeVect

-- | getGeneralSequenceChar encode general (ie not nucleotide or amino acid) sequences
-- as bitvectors,.  Main difference with getSequenceChar is in dealing wioth ambiguities
-- they need to be parsed and "or-ed" differently
getGeneralSequenceChar :: CharInfo -> [ST.ShortText] -> [CharacterData]
getGeneralSequenceChar inCharInfo stateList = 
    if null stateList then error "Empty stateLIst in getGeneralSequenceChar"
    else 
        let stateBVPairVect = getStateBitVectorList $ alphabet inCharInfo
            sequenceVect = V.fromList $ fmap (getGeneralBVCode stateBVPairVect) stateList
            newSequenceChar = CharacterData  {  stateBVPrelim = sequenceVect
                                              , minRangePrelim = V.empty
                                              , maxRangePrelim = V.empty
                                              , matrixStatesPrelim = V.empty
                                              , stateBVFinal = sequenceVect
                                              , minRangeFinal = V.empty
                                              , maxRangeFinal = V.empty
                                              , matrixStatesFinal = V.empty
                                              , approxMatrixCost = V.singleton 0
                                              , localCostVect = V.singleton 0
                                              , localCost = 0.0
                                              , globalCost = 0.0
                                              }
        in
        [newSequenceChar]
        
-- | createLeafCharacter takes rawData and Charinfo and returns CharcaterData type
-- need to add in missing data as well
createLeafCharacter :: [CharInfo] -> [ST.ShortText] -> [CharacterData]
createLeafCharacter inCharInfoList rawDataList =
    if null inCharInfoList then error "Null data in charInfoList createLeafCharacter"
    else if null rawDataList then
        -- missing data
        getMissingValue inCharInfoList
    else 
        let localCharType = charType $ head inCharInfoList
        in
        if (length inCharInfoList == 1) &&  (localCharType `elem` [SmallAlphSeq, NucSeq, AminoSeq, GenSeq]) then
            --trace ("Sequence character")
            if localCharType == NucSeq then getSequenceChar nucleotideBVPairs rawDataList --single state ambiguity codes
            else if localCharType == AminoSeq then getSequenceChar aminoAcidBVPairs rawDataList --single state ambiguity codes
            else -- non-IUPAC codes 
                getGeneralSequenceChar (head inCharInfoList) rawDataList -- ambiguities different, and alphabet varies with character (potentially)
        else 
            trace ("Non-sequence character")  
            []




