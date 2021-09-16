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


module Input.Reorganize
  ( groupDataByType
  , reBlockData 
  ) where

import qualified Data.List                   as L
import           Data.Maybe
import qualified Data.Text.Lazy              as T
import           Types.Types
import qualified Data.BitVector.LittleEndian as BV
import qualified Data.Vector                 as V
import qualified Utilities.Utilities         as U
import           GeneralUtilities
import qualified SymMatrix                   as S
import           Debug.Trace


-- | reBlockData takes original block assignments--each input file is a block--
-- and compbines, cverted new, deletes empty new blocks from user input
reBlockData :: [(NameText, NameText)] -> ProcessedData -> ProcessedData
reBlockData reBlockPairs inData = 
    if null reBlockPairs then inData
    else 
        trace ("Reblock:" ++ (show reBlockPairs)) 
        inData


-- | groupDataByType takes naive data (ProcessedData) and returns PrcessedData
-- with characters reorganized (within blocks) 
    -- all non-additive (with same weight) merged to a single vector character 
    -- all additive with same alphabet (ie numberical) recoded to single vector
    -- all matrix characters with same costmatrix recoded to single charcater
    -- removes innactive characters
groupDataByType :: ProcessedData -> ProcessedData
groupDataByType (nameVect, nameBVVect, blockDataVect) = 
    let organizedBlockData =  V.map organizeBlockData' blockDataVect
    in
    -- trace ("Before Taxa:" ++ (show $ length nameBVVect) ++ " Blocks:" ++ (show $ length blockDataVect) ++ " Characters:" ++ (show $ fmap length $ fmap thd3 blockDataVect)
    --    ++ "\nAfter Taxa:" ++ (show $ length nameBVVect) ++ " Blocks:" ++ (show $ length organizedBlockData) ++ " Characters:" ++ (show $ fmap length $ fmap thd3 organizedBlockData))
    (nameVect, nameBVVect, organizedBlockData)
    
-- | organizeBlockData' shortcircuits nonExact data types in a block to avoid logic in organizeBlockData
-- should be removed when have better teatment of missing non-exact data and block options
organizeBlockData' :: BlockData -> BlockData
organizeBlockData' localBlockData = 
    let numExactChars = U.getNumberExactCharacters (V.singleton localBlockData)
        numNonExactChars = U.getNumberNonExactCharacters (V.singleton localBlockData)
    in
    if (numExactChars == 0) && (numNonExactChars == 1) then localBlockData
        -- fix for now for partiioned data
    else if (numExactChars == 0) then localBlockData
    else if (numExactChars > 0) && (numNonExactChars > 0) then error "This can't happen until block set implemented"
    else organizeBlockData [] [] [] [] localBlockData

-- | organizeBlockData takes a BlockData element and organizes its character by character type
-- to single add, non-add, matrix, non-exact characters (and those with non-integer weights) are left as is due to their need for 
-- individual traversal graphs
-- second element of tuple is a vector over taxa (leaves on input) with
-- a character vector for each leaf/taxon-- basically a matrix with taxon rows and character columns
-- the character info vector is same size as one for each leaf
-- the first 4 args are accumulators for the character types.  Matrix type is list of list since can have multiple
-- matrices.  All non-Exact are in same pile.  
-- characters with weight > 1 are recoded as multiples of same character, if weight non-integer geoes into the "unchanged" pile
-- when bit packed later (if non-additive) will have only log 64 operations impact
-- the pairs for some data types are to keep track of things that vary--like matrices and non-exact charcater information
organizeBlockData :: [([CharacterData], CharInfo)] 
                  -> [([CharacterData], CharInfo)] 
                  -> [([[CharacterData]], CharInfo)] 
                  -> [([CharacterData], CharInfo)]
                  -> BlockData 
                  -> BlockData
organizeBlockData nonAddCharList addCharList matrixCharListList unchangedCharList (blockName, characterDataVectVect, charInfoVect) =
    -- Bit of a cop out but not managing the missing data in blocks thing for multiple non-exact in block
    -- need to add multiple non-exact in block
    if null charInfoVect then 
        -- concatenate all new characters, reverse (for good measure), and convert to vectors
        -- with unrecoded non-Exact characters and new CharInfo vector (reversed)
        -- need to make sure the character info is in the order of return types--nonAdd, Add, Matrix etc
        {-Will need a function to add all this stuff back together
        (blockNamne, newCharacterVector, newCharInfoVect)
        -}
        --trace ("New Char lengths :" ++ (show (length nonAddCharList, length addCharList, length matrixCharListList, length unchangedCharList))) (
        let (newCharDataVectVect, newCharInfoVect) = makeNewCharacterData nonAddCharList addCharList matrixCharListList unchangedCharList
        in 
        (blockName, newCharDataVectVect, newCharInfoVect)
        -- )
    else 
        -- proceed charcater by character increasing accumulators and consuming character data vector and character infoVect
        -- maybe only accumulate for matrix and non additives? 
        let firstCharacter = V.head charInfoVect
            fCharType = charType firstCharacter
            fCharWeight = weight firstCharacter
            intWeight = doubleAsInt fCharWeight
            fCharMatrix = costMatrix firstCharacter
            fCharActivity = activity firstCharacter
            fAlphabet = alphabet firstCharacter
            firstCharacterTaxa = fmap U.safeVectorHead characterDataVectVect
        in
        -- trace ("FCT: " ++ (show $ length firstCharacterTaxa) ++ " " ++ (show characterDataVectVect)) (
        --trace ("CVDD: " ++ (show (length characterDataVectVect, fmap length characterDataVectVect))) (
        
        -- remove inactive characters
        if fCharActivity == False then 
            -- trace ("Innactive") 
            organizeBlockData nonAddCharList addCharList matrixCharListList unchangedCharList (blockName, (V.map V.tail characterDataVectVect), V.tail charInfoVect)

        -- remove constant/missing characters
        -- <2 becasue could be 0 for all missing (could happen with reduced dataset)
        else if length fAlphabet < 2 then 
            organizeBlockData nonAddCharList addCharList matrixCharListList unchangedCharList (blockName, (V.map V.tail characterDataVectVect), V.tail charInfoVect)

        -- place non-exact and non-integer weight characters in unchangedCharList
        else if (intWeight == Nothing) then 
            -- add to unchanged pile
            let currentUnchangedCharacter = (V.toList firstCharacterTaxa, firstCharacter) 
                
            in 
            -- trace ("Unchanged character:" ++ (show $ length $ fst currentUnchangedCharacter) ++ " Name:" ++ (T.unpack $ name firstCharacter) ++ " " ++ (show (charType firstCharacter))
            --    ++ " " ++ (show $ fst currentUnchangedCharacter)) 
            -- trace ("Character Weight non-integer:" ++ show fCharWeight) 
            organizeBlockData nonAddCharList addCharList matrixCharListList (currentUnchangedCharacter : unchangedCharList)  (blockName, (V.map V.tail characterDataVectVect), V.tail charInfoVect) 
            
        -- issue with the line "firstCharacterTaxa = fmap V.head characterDataVectVect" since miossing character will be empoty and throw an error on V.head
        else if (fCharType `notElem` exactCharacterTypes) 
            then errorWithoutStackTrace "Blocks with more than one Non-Exact Character not yet implemented"

        -- non-additive characters
        else if fCharType == NonAdd then 
            let replicateNumber = fromJust intWeight
                currentNonAdditiveCharacter = (V.toList $ fmap V.head characterDataVectVect, firstCharacter)
            in 
            -- trace ("Non-Additive") (
            if (replicateNumber == 1) then organizeBlockData (currentNonAdditiveCharacter : nonAddCharList) addCharList matrixCharListList unchangedCharList  (blockName, (V.map V.tail characterDataVectVect), V.tail charInfoVect) 
            else organizeBlockData ((replicate replicateNumber currentNonAdditiveCharacter) ++ nonAddCharList) addCharList matrixCharListList unchangedCharList  (blockName, (V.map V.tail characterDataVectVect), V.tail charInfoVect)
            -- )

        -- additive characters    
        else if fCharType == Add then  
            let replicateNumber = fromJust intWeight
                currentAdditiveCharacter = (V.toList $ fmap V.head characterDataVectVect, firstCharacter)
            in  
            -- trace ("Additive") (
            if (replicateNumber == 1) then organizeBlockData nonAddCharList (currentAdditiveCharacter : addCharList) matrixCharListList unchangedCharList  (blockName, (V.map V.tail characterDataVectVect), V.tail charInfoVect)  
            else organizeBlockData nonAddCharList ((replicate replicateNumber currentAdditiveCharacter) ++ addCharList) matrixCharListList unchangedCharList  (blockName, (V.map V.tail characterDataVectVect), V.tail charInfoVect)
            -- )

        -- matrix characters--more complex since need to check for matrix identity
        else if fCharType == Matrix then  
            let replicateNumber = fromJust intWeight
                currentMatrixCharacter = (V.toList $ fmap V.head characterDataVectVect, firstCharacter)
                newMatrixCharacterList = addMatrixCharacter matrixCharListList fCharMatrix currentMatrixCharacter replicateNumber
            in
            -- trace ("Matrix") (
            organizeBlockData nonAddCharList addCharList newMatrixCharacterList unchangedCharList (blockName, (V.map V.tail characterDataVectVect), V.tail charInfoVect)
            -- )

        -- error in thype
        else error ("Unrecognized/nont implemented charcter type: " ++ show fCharType)
        -- )

-- | makeNewCharacterData takes nonAddCharList addCharList matrixCharListList unchangedCharList and synthesises them into new charcter data
-- with a single character for the exact types (nonAdd, Add, Matrix) and mulitple characters for the "unchanged" which includes
-- non-exact characters and those with non-integer weights
-- and character Information vector
-- these only bupdate preliminary of their type--meant to happen before decoration processes
-- emptyCharacter defined in Types
makeNewCharacterData :: [([CharacterData], CharInfo)] 
                     -> [([CharacterData], CharInfo)] 
                     -> [([[CharacterData]], CharInfo)] 
                     -> [([CharacterData], CharInfo)]
                     -> (V.Vector (V.Vector CharacterData), V.Vector CharInfo)
makeNewCharacterData nonAddCharList addCharList matrixCharListList unchangedCharList = 
    let
        -- Non-Additive Characters
        nonAddCharacter = combineNonAdditveCharacters nonAddCharList emptyCharacter []
        nonAddCharInfo = V.singleton $ (snd $ head nonAddCharList) {name = T.pack "CombinedNonAdditiveCharacters"}
        
        -- Additive Characters
        addCharacter = combineAdditveCharacters addCharList emptyCharacter []
        addCharInfo = V.singleton $ (snd $ head addCharList) {name = T.pack "CombinedAdditiveCharacters"}
        -- Matrix Characters
        (matrixCharacters, matrixCharInfoList) = mergeMatrixCharacters matrixCharListList emptyCharacter
        
        -- Unchanged characters 
        -- (unchangedCharacters, unchangeCharacterInfoList) = combineUnchangedCharacters unchangedCharList 
        
        -- buildList incrementally
        newCharacterList' = if null nonAddCharacter then []
                            else [nonAddCharacter]
        newCharacterList'' = if (null addCharacter) then newCharacterList'
                             else (addCharacter) : newCharacterList'
        newCharacterList''' = newCharacterList'' ++ (matrixCharacters)

        newChararacterInfoList' = if null nonAddCharacter then []
                                  else [nonAddCharInfo]
        newChararacterInfoList'' = if null addCharacter then newChararacterInfoList'
                                  else addCharInfo : newChararacterInfoList'
        newChararacterInfoList''' = newChararacterInfoList'' ++ (fmap V.singleton matrixCharInfoList)
        
    in
    {-
    trace ("Recoded Non-Additive: " ++ (show $ length nonAddCharList) ++ "->" ++ (show (length nonAddCharacter, fmap length $ fmap stateBVPrelim nonAddCharacter))
        ++ " Additive: " ++ (show $ length addCharList) ++ "->" ++ (show (length addCharacter, fmap length $ fmap rangePrelim addCharacter))
        ++ " Matrix " ++ (show  $length matrixCharListList) ++ "->" ++ (show $ length matrixCharacters)
        ++ " total list: " ++ (show (length newCharacterList''', fmap length newCharacterList''')) ++ " CI " ++ (show $ length newChararacterInfoList'''))
    -}
    (V.fromList $ fmap V.fromList $ L.transpose newCharacterList''', V.concat newChararacterInfoList''')

{-
-- | combineUnchangedCharacters takes the list of unchanged characters (ie not merged) and recreates a list of them
-- reversing to keep original order
combineUnchangedCharacters :: [([CharacterData], CharInfo)] -> ([[CharacterData]], [CharInfo])
combineUnchangedCharacters unchangedCharListList = 
    if null unchangedCharListList then ([], [])
    else
        let (newCharList, newCharInfoList) = unzip unchangedCharListList
        in 
        -- trace ("Combined unchanged " ++ (show (length newCharList, fmap length newCharList)))
        (L.transpose newCharList, newCharInfoList)
-}

-- | combineMatrixCharacters cretes a series of lists of characters each of which has a different cost matrix
-- each character "type" (based on matrix) can have 1 or more characters 
mergeMatrixCharacters :: [([[CharacterData]], CharInfo)] -> CharacterData -> ([[CharacterData]], [CharInfo])
mergeMatrixCharacters inMatrixCharListList charTemplate =
    -- should probably reverse the characters to maintian similar ordering to input
    let (charDataList, charInfoList) = unzip inMatrixCharListList
        combinedMatrixCharList = fmap (combineMatrixCharacters charTemplate []) charDataList
    in
    (combinedMatrixCharList, charInfoList)

-- | combineMatrixCharacters takes all matrix characters with same cost matrix and combines into
-- a single character with vector of original characters
combineMatrixCharacters :: CharacterData -> [[V.Vector MatrixTriple]] -> [[CharacterData]] -> [CharacterData]
combineMatrixCharacters charTemplate currentTripleList inMatrixCharDataList =
   if null inMatrixCharDataList then 
      -- create character vector for preliminary states concatenating by taxon
      let taxRowCharList = L.transpose currentTripleList
          newCharacterData = fmap (makeMatrixCharacterList charTemplate) taxRowCharList
      in
      newCharacterData
   else 
        -- first Character
        let charDataList = head inMatrixCharDataList
            prelimTripleList = fmap V.head $ fmap matrixStatesPrelim charDataList
        in
        combineMatrixCharacters charTemplate (prelimTripleList : currentTripleList) (tail inMatrixCharDataList) 

-- | makeMatrixCharacterList takes a taxon list of matrix characters 
-- and converts to single vector and makes new character for the taxon
makeMatrixCharacterList :: CharacterData -> [V.Vector MatrixTriple] -> CharacterData
makeMatrixCharacterList charTemplate tripleList = charTemplate {matrixStatesPrelim = V.fromList tripleList}

-- | combineNonAdditveCharacters takes a list of character data with singleton non-additive characters and puts 
-- them together in a single character for each taxon
combineNonAdditveCharacters :: [([CharacterData], CharInfo)] -> CharacterData -> [[BV.BitVector]] -> [CharacterData]
combineNonAdditveCharacters nonAddCharList charTemplate currentBVList =
    if null nonAddCharList then
        -- create character vector for preliminary states concatenating by taxon
        -- single created and redone twice with prepend no need to reverse (that there really is anyway)
        let taxRowCharList = L.transpose currentBVList
            newCharacterData = fmap (makeNonAddCharacterList charTemplate) taxRowCharList
        in
        newCharacterData
    else 
        -- first Character
        let (charDataList, _) = head nonAddCharList
            prelimBVList = fmap V.head $ fmap fst3 $ fmap stateBVPrelim charDataList
        in
        combineNonAdditveCharacters (tail nonAddCharList) charTemplate (prelimBVList : currentBVList)

-- | combineAdditveCharacters takes a list of character data with singleton non-additive characters and puts 
-- them together in a single character for each taxon
combineAdditveCharacters :: [([CharacterData], CharInfo)] -> CharacterData -> [[(Int, Int)]] -> [CharacterData]
combineAdditveCharacters addCharList charTemplate currentRangeList =
    if null addCharList then
        -- create character vector for preliminary states concatenating by taxon
        -- single created and redone twice with prepend no need to reverse (that there really is anyway)
        let taxRowCharList = L.transpose currentRangeList
            newCharacterData = fmap (makeAddCharacterList charTemplate) taxRowCharList
        in
        newCharacterData
    else 
        -- first Character
        let (charDataList, _) = head addCharList
            prelimRangeList = fmap V.head $ fmap fst3 $ fmap rangePrelim charDataList
        in
        combineAdditveCharacters (tail addCharList) charTemplate (prelimRangeList : currentRangeList)

-- | makeNonAddCharacterList takes a taxon list of characters 
-- convertes chars to single vector and makes new character for the taxon
-- assumes a leaf so snd and 3rd fields are mempty
makeNonAddCharacterList :: CharacterData -> [BV.BitVector] -> CharacterData
makeNonAddCharacterList charTemplate bvList = charTemplate {stateBVPrelim = (V.fromList bvList, mempty, mempty)}

-- | makeAddCharacterList takes a taxon list of characters 
-- to single vector and makes new character for the taxon
-- assums a leaf so snd and 3rd fileds are mempty
makeAddCharacterList :: CharacterData -> [(Int, Int)] -> CharacterData
makeAddCharacterList charTemplate rangeList = charTemplate {rangePrelim = (V.fromList rangeList, mempty, mempty)}

-- | addMatrixCharacter adds a matrix character to the appropriate (by cost matrix) list of matrix characters 
-- replicates character by integer weight 
addMatrixCharacter :: [([[CharacterData]], CharInfo)] -> S.Matrix Int -> ([CharacterData], CharInfo)-> Int -> [([[CharacterData]], CharInfo)] 
addMatrixCharacter inMatrixCharacterList currentCostMatrix currentMatrixCharacter replicateNumber =
    if null inMatrixCharacterList then
        -- didn't find a match --so need to add new type to list of matrix character types
        if replicateNumber == 1 then 
                [([(fst currentMatrixCharacter)], snd currentMatrixCharacter)]

            else
                [((replicate replicateNumber $ fst currentMatrixCharacter), snd currentMatrixCharacter)]       

    else    
        let firstList@(firstMatrixCharList, localCharInfo) = head inMatrixCharacterList
            firstMatrix = costMatrix localCharInfo
        in

        -- matrices match--so correct matrix character type
        if firstMatrix == currentCostMatrix then 
            if replicateNumber == 1 then 
                ((fst currentMatrixCharacter) : firstMatrixCharList, localCharInfo) : (tail inMatrixCharacterList)

            else
                ((replicate replicateNumber $ fst currentMatrixCharacter) ++ firstMatrixCharList, localCharInfo) : (tail inMatrixCharacterList)

        -- matrices don't match so recurse to next one
        else firstList : addMatrixCharacter (tail inMatrixCharacterList) currentCostMatrix currentMatrixCharacter replicateNumber 


