{- |
Module specifying graph egde adding and deleting functions
-}
module Search.NetworkAddDelete (
    deleteAllNetEdges,
    insertAllNetEdges,
    moveAllNetEdges,
    deltaPenaltyAdjustment,
    deleteNetEdge,
    deleteOneNetAddAll,
    addDeleteNetEdges,
    getCharacterDelta,
    getBlockDelta,
    -- these are not used but to quiet warnings
    heuristicDeleteDelta,
    heuristicAddDelta,
    heuristicAddDelta',
) where

import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Bits
import Data.InfList qualified as IL
import Data.Maybe
import Data.Text.Lazy qualified as TL
import Data.Vector qualified as V
import GeneralUtilities
import GraphOptimization.Medians qualified as M
import GraphOptimization.PostOrderSoftWiredFunctions qualified as POSW
import GraphOptimization.PostOrderSoftWiredFunctionsNew qualified as NEW
import GraphOptimization.PreOrderFunctions qualified as PRE
import GraphOptimization.Traversals qualified as T
import Graphs.GraphOperations qualified as GO
import PHANE.Evaluation
import PHANE.Evaluation.ErrorPhase (ErrorPhase (..))
import PHANE.Evaluation.Logging
import PHANE.Evaluation.Verbosity (Verbosity (..))
import Types.Types
import Utilities.LocalGraph qualified as LG
import Utilities.Utilities qualified as U


-- import Debug.Trace
-- import ParallelUtilities qualified as PU

{- |
'addDeleteNetEdges' is a wrapper for 'addDeleteNetEdges'' allowing for multiple simulated annealing rounds.
-}
addDeleteNetEdges
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Int
    → Int
    → Int
    → Bool
    → Bool
    → Bool
    → ([ReducedPhylogeneticGraph], VertexCost)
    → (Maybe SAParams, [ReducedPhylogeneticGraph])
    → PhyG ([ReducedPhylogeneticGraph], Int)
addDeleteNetEdges inGS inData rSeed maxNetEdges numToKeep maxRounds counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost) (inSimAnnealParams, inPhyloGraphList) =
    if isNothing inSimAnnealParams
        then do
            addDeleteNetEdges'
                inGS
                inData
                rSeed
                maxNetEdges
                numToKeep
                maxRounds
                counter
                returnMutated
                doSteepest
                doRandomOrder
                (curBestGraphList, curBestGraphCost)
                Nothing
                inPhyloGraphList
        else
            let -- create list of params with unique list of random values for rounds of annealing
                annealingRounds = rounds $ fromJust inSimAnnealParams
                saPAramList = (U.generateUniqueRandList annealingRounds inSimAnnealParams) -- (replicate annealingRounds inPhyloGraphList)

                -- parallel setup
                action ∷ (Maybe SAParams, [ReducedPhylogeneticGraph]) → PhyG ([ReducedPhylogeneticGraph], Int)
                action =
                    addDeleteNetEdges''
                        inGS
                        inData
                        rSeed
                        maxNetEdges
                        numToKeep
                        maxRounds
                        counter
                        returnMutated
                        doSteepest
                        doRandomOrder
                        (curBestGraphList, curBestGraphCost)
            in  do
                    -- TODO
                    pTraverse ← getParallelChunkTraverse
                    addDeleteResult ← pTraverse action (zip saPAramList (replicate annealingRounds inPhyloGraphList))
                    -- mapM (addDeleteNetEdges'' inGS inData rSeed maxNetEdges numToKeep maxRounds counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost)) (zip saPAramList (replicate annealingRounds inPhyloGraphList))
                    let (annealRoundsList, counterList) = unzip addDeleteResult
                    -- (annealRoundsList, counterList) = unzip (PU.seqParMap (parStrategy $ strictParStrat inGS) (addDeleteNetEdges'' inGS inData rSeed maxNetEdges numToKeep maxRounds counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost)) (zip saPAramList (replicate annealingRounds inPhyloGraphList)))

                    pure (GO.selectGraphs Best numToKeep 0.0 (-1) (concat annealRoundsList), sum counterList)


-- | addDeleteNetEdges'' is wrapper around addDeleteNetEdges' to use parmap
addDeleteNetEdges''
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Int
    → Int
    → Int
    → Bool
    → Bool
    → Bool
    → ([ReducedPhylogeneticGraph], VertexCost)
    → (Maybe SAParams, [ReducedPhylogeneticGraph])
    → PhyG ([ReducedPhylogeneticGraph], Int)
addDeleteNetEdges'' inGS inData rSeed maxNetEdges numToKeep maxRounds counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost) (inSimAnnealParams, inPhyloGraphList) =
    addDeleteNetEdges'
        inGS
        inData
        rSeed
        maxNetEdges
        numToKeep
        maxRounds
        counter
        returnMutated
        doSteepest
        doRandomOrder
        (curBestGraphList, curBestGraphCost)
        inSimAnnealParams
        inPhyloGraphList


{- | addDeleteNetEdges' removes each edge and adds an edge to all possible places (or steepest) each round
until no better or additional graphs are found (or max rounds met)
call with ([], infinity) [single input graph]
doesn't have to be random, but likely to converge quickly if not
-}
addDeleteNetEdges'
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Int
    → Int
    → Int
    → Bool
    → Bool
    → Bool
    → ([ReducedPhylogeneticGraph], VertexCost)
    → Maybe SAParams
    → [ReducedPhylogeneticGraph]
    → PhyG ([ReducedPhylogeneticGraph], Int)
addDeleteNetEdges' inGS inData rSeed maxNetEdges numToKeep maxRounds counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost) inSimAnnealParams inPhyloGraphList =
    if null inPhyloGraphList
        then do
            pure (take numToKeep curBestGraphList, counter)
        else -- if hit maxmimum rounds then return

            if counter == maxRounds
                then do
                    pure (take numToKeep curBestGraphList, counter)
                else -- other wise add/delete
                do
                    -- trace ("\tRound " <> (show counter)) (
                    -- insert edges first
                    let randIntList = randomIntList rSeed
                    (insertGraphList, _) ←
                        insertAllNetEdges'
                            inGS
                            inData
                            maxNetEdges
                            numToKeep
                            counter
                            returnMutated
                            doSteepest
                            doRandomOrder
                            (curBestGraphList, curBestGraphCost)
                            randIntList
                            inSimAnnealParams
                            inPhyloGraphList

                    -- this to update randlists in SAPArams for subsequent calls
                    let updatedSAParamList =
                            if isJust inSimAnnealParams
                                then U.generateUniqueRandList 2 inSimAnnealParams
                                else [Nothing, Nothing]

                    -- if no better--take input for delte phase
                    let randIntList2 = randomIntList (randIntList !! 1)
                    let (insertGraphList', insertGraphCost, toDeleteList) =
                            if null insertGraphList
                                then (curBestGraphList, curBestGraphCost, inPhyloGraphList)
                                else
                                    let newList = GO.selectGraphs Best (maxBound ∷ Int) 0.0 (-1) insertGraphList
                                    in  (newList, snd5 $ head newList, newList)
                    -- delete edges
                    (deleteGraphList, _) ←
                        deleteAllNetEdges'
                            inGS
                            inData
                            maxNetEdges
                            numToKeep
                            counter
                            returnMutated
                            doSteepest
                            doRandomOrder
                            (insertGraphList', insertGraphCost)
                            randIntList2
                            (head updatedSAParamList)
                            toDeleteList

                    -- gather beter if any
                    let (newBestGraphList, newBestGraphCost, graphsToDoNext) =
                            if null deleteGraphList
                                then (curBestGraphList, curBestGraphCost, inPhyloGraphList)
                                else
                                    let newDeleteGraphs = GO.selectGraphs Best (maxBound ∷ Int) 0.0 (-1) deleteGraphList
                                    in  (newDeleteGraphs, snd5 $ head newDeleteGraphs, newDeleteGraphs)

                    -- check is same then return
                    if newBestGraphCost == curBestGraphCost
                        then do
                            pure (take numToKeep curBestGraphList, counter)
                        else -- if better (or nothing) keep going
                        do
                            addDeleteNetEdges'
                                inGS
                                inData
                                (randIntList !! 2)
                                maxNetEdges
                                numToKeep
                                maxRounds
                                (counter + 1)
                                returnMutated
                                doSteepest
                                doRandomOrder
                                (newBestGraphList, newBestGraphCost)
                                (last updatedSAParamList)
                                graphsToDoNext


-- )

-- | moveAllNetEdges is a wrapper for moveAllNetEdges' allowing for multiple simulated annealing rounds
moveAllNetEdges
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Int
    → Int
    → Bool
    → Bool
    → Bool
    → ([ReducedPhylogeneticGraph], VertexCost)
    → (Maybe SAParams, [ReducedPhylogeneticGraph])
    → PhyG ([ReducedPhylogeneticGraph], Int)
moveAllNetEdges inGS inData rSeed maxNetEdges numToKeep counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost) (inSimAnnealParams, inPhyloGraphList) =
    if isNothing inSimAnnealParams
        then do
            moveAllNetEdges'
                inGS
                inData
                rSeed
                maxNetEdges
                numToKeep
                counter
                returnMutated
                doSteepest
                doRandomOrder
                (curBestGraphList, curBestGraphCost)
                Nothing
                inPhyloGraphList
        else
            let -- create list of params with unique list of random values for rounds of annealing
                annealingRounds = rounds $ fromJust inSimAnnealParams
                saPAramList = (U.generateUniqueRandList annealingRounds inSimAnnealParams) -- (replicate annealingRounds inPhyloGraphList)

                -- paralle setup
                action ∷ (Maybe SAParams, [ReducedPhylogeneticGraph]) → PhyG ([ReducedPhylogeneticGraph], Int)
                action =
                    moveAllNetEdges''
                        inGS
                        inData
                        rSeed
                        maxNetEdges
                        numToKeep
                        counter
                        returnMutated
                        doSteepest
                        doRandomOrder
                        (curBestGraphList, curBestGraphCost)
            in  do
                    -- TODO
                    -- (annealRoundsList, counterList) = unzip (PU.seqParMap (parStrategy $ strictParStrat inGS) (moveAllNetEdges'' inGS inData rSeed maxNetEdges numToKeep counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost)) (zip saPAramList (replicate annealingRounds inPhyloGraphList)))
                    pTraverse ← getParallelChunkTraverse
                    moveResult ← pTraverse action (zip saPAramList (replicate annealingRounds inPhyloGraphList))
                    -- mapM (moveAllNetEdges'' inGS inData rSeed maxNetEdges numToKeep counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost)) (zip saPAramList (replicate annealingRounds inPhyloGraphList))
                    let (annealRoundsList, counterList) = unzip moveResult

                    pure (GO.selectGraphs Best numToKeep 0.0 (-1) (concat annealRoundsList), sum counterList)


-- | moveAllNetEdges'' is wrapper around moveAllNetEdges' to use parmap
moveAllNetEdges''
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Int
    → Int
    → Bool
    → Bool
    → Bool
    → ([ReducedPhylogeneticGraph], VertexCost)
    → (Maybe SAParams, [ReducedPhylogeneticGraph])
    → PhyG ([ReducedPhylogeneticGraph], Int)
moveAllNetEdges'' inGS inData rSeed maxNetEdges numToKeep counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost) (inSimAnnealParams, inPhyloGraphList) =
    moveAllNetEdges'
        inGS
        inData
        rSeed
        maxNetEdges
        numToKeep
        counter
        returnMutated
        doSteepest
        doRandomOrder
        (curBestGraphList, curBestGraphCost)
        inSimAnnealParams
        inPhyloGraphList


{- | moveAllNetEdges' removes each edge and adds an edge to all possible places (or steepest) each round
until no better or additional graphs are found
call with ([], infinity) [single input graph]
-}
moveAllNetEdges'
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Int
    → Int
    → Bool
    → Bool
    → Bool
    → ([ReducedPhylogeneticGraph], VertexCost)
    → Maybe SAParams
    → [ReducedPhylogeneticGraph]
    → PhyG ([ReducedPhylogeneticGraph], Int)
moveAllNetEdges' inGS inData rSeed maxNetEdges numToKeep counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost) inSimAnnealParams inPhyloGraphList =
    if null inPhyloGraphList
        then do
            pure (take numToKeep curBestGraphList, counter)
        else
            if LG.isEmpty $ fst5 $ head inPhyloGraphList
                then
                    moveAllNetEdges'
                        inGS
                        inData
                        rSeed
                        maxNetEdges
                        numToKeep
                        counter
                        returnMutated
                        doSteepest
                        doRandomOrder
                        (curBestGraphList, curBestGraphCost)
                        inSimAnnealParams
                        (tail inPhyloGraphList)
                else
                    let firstPhyloGraph = head inPhyloGraphList
                        currentCost = min curBestGraphCost (snd5 firstPhyloGraph)

                        -- randomize order of edges to try moving
                        netEdgeList =
                            if not doRandomOrder
                                then LG.labNetEdges (thd5 firstPhyloGraph)
                                else permuteList rSeed $ LG.labNetEdges (thd5 firstPhyloGraph)
                        -- paralle setup
                        action ∷ LG.Edge → PhyG [ReducedPhylogeneticGraph]
                        action = deleteOneNetAddAll' inGS inData maxNetEdges numToKeep doSteepest doRandomOrder firstPhyloGraph rSeed inSimAnnealParams
                    in  do
                            -- TODO
                            -- newGraphList' =  concat $ PU.seqParMap (parStrategy $ strictParStrat inGS) (deleteOneNetAddAll' inGS inData maxNetEdges numToKeep doSteepest doRandomOrder firstPhyloGraph rSeed inSimAnnealParams) (fmap LG.toEdge netEdgeList)
                            pTraverse ← getParallelChunkTraverse
                            deleteResult ← pTraverse action (fmap LG.toEdge netEdgeList)
                            -- mapM (deleteOneNetAddAll' inGS inData maxNetEdges numToKeep doSteepest doRandomOrder firstPhyloGraph rSeed inSimAnnealParams) (fmap LG.toEdge netEdgeList)
                            let newGraphList' = concat deleteResult

                            -- newGraphList' =  deleteOneNetAddAll inGS inData maxNetEdges numToKeep doSteepest doRandomOrder firstPhyloGraph (fmap LG.toEdge netEdgeList) rSeed inSimAnnealParams

                            let newGraphList = GO.selectGraphs Best numToKeep 0.0 (-1) newGraphList'
                            let newGraphCost =
                                    if (not . null) newGraphList'
                                        then snd5 $ head newGraphList
                                        else infinity

                            -- if graph is a tree no edges to delete
                            if null netEdgeList
                                then do
                                    logWith LogInfo ("\t\tGraph in move has no network edges to move--skipping" <> "\n")
                                    pure (inPhyloGraphList, counter)
                                else -- regular move keeping best

                                    if isNothing inSimAnnealParams
                                        then
                                            if newGraphCost > currentCost
                                                then do
                                                    -- trace ("\t MANE : Worse")
                                                    moveAllNetEdges'
                                                        inGS
                                                        inData
                                                        maxNetEdges
                                                        rSeed
                                                        numToKeep
                                                        (counter + 1)
                                                        returnMutated
                                                        doSteepest
                                                        doRandomOrder
                                                        (firstPhyloGraph : curBestGraphList, currentCost)
                                                        inSimAnnealParams
                                                        (tail inPhyloGraphList)
                                                else
                                                    if newGraphCost < currentCost
                                                        then -- trace ("\tMANE-> " <> (show newGraphCost)) (

                                                            if doSteepest
                                                                then do
                                                                    moveAllNetEdges'
                                                                        inGS
                                                                        inData
                                                                        rSeed
                                                                        maxNetEdges
                                                                        numToKeep
                                                                        (counter + 1)
                                                                        returnMutated
                                                                        doSteepest
                                                                        doRandomOrder
                                                                        (newGraphList, newGraphCost)
                                                                        inSimAnnealParams
                                                                        newGraphList
                                                                else do
                                                                    moveAllNetEdges'
                                                                        inGS
                                                                        inData
                                                                        rSeed
                                                                        maxNetEdges
                                                                        numToKeep
                                                                        (counter + 1)
                                                                        returnMutated
                                                                        doSteepest
                                                                        doRandomOrder
                                                                        (newGraphList, newGraphCost)
                                                                        inSimAnnealParams
                                                                        (newGraphList <> (tail inPhyloGraphList))
                                                        else -- )

                                                        do
                                                            -- new graph list contains the input graph if equal and filterd unique already in moveAllNetEdges
                                                            let newCurSameBestList = GO.selectGraphs Unique numToKeep 0.0 (-1) (curBestGraphList <> newGraphList)

                                                            -- trace ("\t MANE : Equal")
                                                            moveAllNetEdges'
                                                                inGS
                                                                inData
                                                                rSeed
                                                                maxNetEdges
                                                                numToKeep
                                                                (counter + 1)
                                                                returnMutated
                                                                doSteepest
                                                                doRandomOrder
                                                                (newCurSameBestList, currentCost)
                                                                inSimAnnealParams
                                                                (tail inPhyloGraphList)
                                        else -- sim anneal choice

                                            if True
                                                then errorWithoutStackTrace "Simulated Annealing/Drift not implemented for Network Move"
                                                else
                                                    let -- abstract stopping criterion to continue
                                                        numDone =
                                                            if (method $ fromJust inSimAnnealParams) == SimAnneal
                                                                then currentStep $ fromJust inSimAnnealParams
                                                                else driftChanges $ fromJust inSimAnnealParams
                                                        numMax =
                                                            if (method $ fromJust inSimAnnealParams) == SimAnneal
                                                                then numberSteps $ fromJust inSimAnnealParams
                                                                else driftMaxChanges $ fromJust inSimAnnealParams

                                                        -- get acceptance based on heuristic costs
                                                        uniqueGraphList = GO.selectGraphs Unique numToKeep 0.0 (-1) newGraphList'
                                                        annealBestCost =
                                                            if (not . null) uniqueGraphList
                                                                then min curBestGraphCost (snd5 $ head uniqueGraphList)
                                                                else curBestGraphCost
                                                        (acceptFirstGraph, newSAParams) =
                                                            if (not . null) uniqueGraphList
                                                                then U.simAnnealAccept inSimAnnealParams annealBestCost (snd5 $ head uniqueGraphList)
                                                                else (False, U.incrementSimAnnealParams inSimAnnealParams)
                                                    in  -- trace ("ACG" <> (show acceptFirstGraph) <> " " <> (show $ snd5 $ head uniqueGraphList)) (
                                                        if (numDone < numMax)
                                                            then -- this fixes tail fail

                                                                let nextUniqueList =
                                                                        if (not . null) uniqueGraphList
                                                                            then tail uniqueGraphList
                                                                            else []
                                                                in  if acceptFirstGraph
                                                                        then do
                                                                            moveAllNetEdges'
                                                                                inGS
                                                                                inData
                                                                                rSeed
                                                                                maxNetEdges
                                                                                numToKeep
                                                                                (counter + 1)
                                                                                returnMutated
                                                                                doSteepest
                                                                                doRandomOrder
                                                                                ((head uniqueGraphList) : curBestGraphList, annealBestCost)
                                                                                newSAParams
                                                                                (nextUniqueList <> (tail inPhyloGraphList))
                                                                        else do
                                                                            moveAllNetEdges'
                                                                                inGS
                                                                                inData
                                                                                rSeed
                                                                                maxNetEdges
                                                                                numToKeep
                                                                                (counter + 1)
                                                                                returnMutated
                                                                                doSteepest
                                                                                doRandomOrder
                                                                                (curBestGraphList, annealBestCost)
                                                                                newSAParams
                                                                                (nextUniqueList <> (tail inPhyloGraphList))
                                                            else -- if want non-optimized list for GA or whatever

                                                                if returnMutated
                                                                    then do
                                                                        pure (take numToKeep curBestGraphList, counter)
                                                                    else -- optimize list and return
                                                                    do
                                                                        (bestMoveList', counter') ←
                                                                            moveAllNetEdges'
                                                                                inGS
                                                                                inData
                                                                                rSeed
                                                                                maxNetEdges
                                                                                numToKeep
                                                                                (counter + 1)
                                                                                False
                                                                                doSteepest
                                                                                doRandomOrder
                                                                                ([], annealBestCost)
                                                                                Nothing
                                                                                (take numToKeep curBestGraphList)
                                                                        let bestMoveList = GO.selectGraphs Best numToKeep 0.0 (-1) bestMoveList'

                                                                        -- trace ("BM: " <> (show $ snd5 $ head  bestMoveList))
                                                                        pure (take numToKeep bestMoveList, counter')


-- )

-- | (curBestGraphList, annealBestCost) is a wrapper for moveAllNetEdges' allowing for multiple simulated annealing rounds
insertAllNetEdges
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Int
    → Int
    → Int
    → Bool
    → Bool
    → Bool
    → ([ReducedPhylogeneticGraph], VertexCost)
    → (Maybe SAParams, [ReducedPhylogeneticGraph])
    → PhyG ([ReducedPhylogeneticGraph], Int)
insertAllNetEdges inGS inData rSeed maxNetEdges numToKeep maxRounds counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost) (inSimAnnealParams, inPhyloGraphList) =
    let -- parallel setup
        randAction ∷ [Int] → PhyG ([ReducedPhylogeneticGraph], Int)
        randAction =
            insertAllNetEdgesRand
                inGS
                inData
                maxNetEdges
                numToKeep
                counter
                returnMutated
                doSteepest
                (curBestGraphList, curBestGraphCost)
                Nothing
                inPhyloGraphList

        action ∷ ([Int], Maybe SAParams, [ReducedPhylogeneticGraph]) → PhyG ([ReducedPhylogeneticGraph], Int)
        action =
            insertAllNetEdges''
                inGS
                inData
                maxNetEdges
                numToKeep
                counter
                returnMutated
                doSteepest
                doRandomOrder
                (curBestGraphList, curBestGraphCost)
    in  if isNothing inSimAnnealParams
            then -- check for multiple rounds of addition--if > 1 then need to randomize order

                if maxRounds == 1
                    then
                        insertAllNetEdges'
                            inGS
                            inData
                            maxNetEdges
                            numToKeep
                            counter
                            returnMutated
                            doSteepest
                            doRandomOrder
                            (curBestGraphList, curBestGraphCost)
                            (randomIntList rSeed)
                            Nothing
                            inPhyloGraphList
                    else do
                        -- need to concat and send different randomization lists for each "round"
                        let randSeedList = take maxRounds (randomIntList rSeed)
                        let randIntListList = fmap randomIntList randSeedList
                        -- TODO
                        -- (insertGraphList, counterList) = unzip $ PU.seqParMap (parStrategy $ strictParStrat inGS) (insertAllNetEdgesRand inGS inData maxNetEdges numToKeep counter returnMutated doSteepest (curBestGraphList, curBestGraphCost) Nothing inPhyloGraphList) randIntListList
                        randPar ← getParallelChunkTraverse
                        insertGraphResult ← randPar randAction randIntListList
                        -- mapM (insertAllNetEdgesRand inGS inData maxNetEdges numToKeep counter returnMutated doSteepest (curBestGraphList, curBestGraphCost) Nothing inPhyloGraphList) randIntListList
                        let (insertGraphList, counterList) = unzip insertGraphResult
                        -- insert functions take care of returning "better" or empty
                        -- should be empty if nothing better
                        pure (GO.selectGraphs Best numToKeep 0.0 (-1) (concat insertGraphList), sum counterList)
            else
                let -- create list of params with unique list of random values for rounds of annealing
                    annealingRounds = rounds $ fromJust inSimAnnealParams
                    annealParamGraphList = U.generateUniqueRandList annealingRounds inSimAnnealParams
                    replicateRandIntList = fmap randomIntList (take annealingRounds (randomIntList rSeed))
                in  do
                        -- TODO
                        -- (annealRoundsList, counterList) = unzip (PU.seqParMap (parStrategy $ strictParStrat inGS) (insertAllNetEdges'' inGS inData maxNetEdges numToKeep counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost)) (zip3 replicateRandIntList annealParamGraphList (replicate annealingRounds inPhyloGraphList)))
                        actionPar ← getParallelChunkTraverse
                        insertGraphResult ←
                            actionPar action (zip3 replicateRandIntList annealParamGraphList (replicate annealingRounds inPhyloGraphList))
                        -- mapM (insertAllNetEdges'' inGS inData maxNetEdges numToKeep counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost)) (zip3 replicateRandIntList annealParamGraphList (replicate annealingRounds inPhyloGraphList))
                        let (annealRoundsList, counterList) = unzip insertGraphResult
                        if (not returnMutated) || isNothing inSimAnnealParams
                            then do
                                pure (GO.selectGraphs Best numToKeep 0.0 (-1) (concat annealRoundsList), sum counterList)
                            else do
                                pure (GO.selectGraphs Unique numToKeep 0.0 (-1) (concat annealRoundsList), sum counterList)


-- | insertAllNetEdgesRand is a wrapper around insertAllNetEdges'' to pass unique randomLists to insertAllNetEdges'
insertAllNetEdgesRand
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Int
    → Bool
    → Bool
    → ([ReducedPhylogeneticGraph], VertexCost)
    → Maybe SAParams
    → [ReducedPhylogeneticGraph]
    → [Int]
    → PhyG ([ReducedPhylogeneticGraph], Int)
insertAllNetEdgesRand inGS inData maxNetEdges numToKeep counter returnMutated doSteepest (curBestGraphList, curBestGraphCost) inSimAnnealParams inPhyloGraphList randIntList =
    insertAllNetEdges'
        inGS
        inData
        maxNetEdges
        numToKeep
        counter
        returnMutated
        doSteepest
        True
        (curBestGraphList, curBestGraphCost)
        randIntList
        inSimAnnealParams
        inPhyloGraphList


-- | insertAllNetEdges'' is a wrapper around insertAllNetEdges' to allow for seqParMap
insertAllNetEdges''
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Int
    → Bool
    → Bool
    → Bool
    → ([ReducedPhylogeneticGraph], VertexCost)
    → ([Int], Maybe SAParams, [ReducedPhylogeneticGraph])
    → PhyG ([ReducedPhylogeneticGraph], Int)
insertAllNetEdges'' inGS inData maxNetEdges numToKeep counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost) (randIntList, inSimAnnealParams, inPhyloGraphList) =
    insertAllNetEdges'
        inGS
        inData
        maxNetEdges
        numToKeep
        counter
        returnMutated
        doSteepest
        doRandomOrder
        (curBestGraphList, curBestGraphCost)
        randIntList
        inSimAnnealParams
        inPhyloGraphList


{- | insertAllNetEdges' adds network edges one each each round until no better or additional
graphs are found
call with ([], infinity) [single input graph]
-}
insertAllNetEdges'
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Int
    → Bool
    → Bool
    → Bool
    → ([ReducedPhylogeneticGraph], VertexCost)
    → [Int]
    → Maybe SAParams
    → [ReducedPhylogeneticGraph]
    → PhyG ([ReducedPhylogeneticGraph], Int)
insertAllNetEdges' inGS inData maxNetEdges numToKeep counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost) randIntList inSimAnnealParams inPhyloGraphList =
    if null inPhyloGraphList
        then -- this logic so don't return mutated if finish insertion before hitting other stopping points
        -- and don't want mutated--straight deletion on current best graphs

            if isNothing inSimAnnealParams || returnMutated
                then do
                    pure (take numToKeep curBestGraphList, counter)
                else
                    deleteAllNetEdges'
                        inGS
                        inData
                        maxNetEdges
                        numToKeep
                        counter
                        False
                        doSteepest
                        doRandomOrder
                        ([], curBestGraphCost)
                        (randomIntList $ head randIntList)
                        Nothing
                        (take numToKeep curBestGraphList)
        else
            let currentCost = min curBestGraphCost (snd5 $ head inPhyloGraphList)

                -- check for max net edges
                (_, _, _, netNodes) = LG.splitVertexList (thd5 $ head inPhyloGraphList)
            in  do
                    (newGraphList, _, newSAParams) ←
                        insertEachNetEdge
                            inGS
                            inData
                            (head randIntList)
                            maxNetEdges
                            numToKeep
                            doSteepest
                            doRandomOrder
                            Nothing
                            inSimAnnealParams
                            (head inPhyloGraphList)

                    let bestNewGraphList = GO.selectGraphs Best numToKeep 0.0 (-1) newGraphList
                    let newGraphCost =
                            if (not . null) bestNewGraphList
                                then snd5 $ head bestNewGraphList
                                else infinity

                    logWith LogInfo ("\t\tNumber of network edges: " <> (show $ length netNodes) <> "\n")
                    -- trace ("IANE: " <> (show $ length netNodes)) (
                    if length netNodes >= maxNetEdges
                        then do
                            logWith LogInfo ("Maximum number of network edges reached: " <> (show $ length netNodes) <> "\n")
                            pure (take numToKeep curBestGraphList, counter)
                        else
                            if null newGraphList
                                then do
                                    logWith LogInfo ("\t\tNumber of network edges: " <> (show $ length netNodes) <> "\n")
                                    pure (take numToKeep curBestGraphList, counter)
                                else -- regular insert keeping best

                                    if isNothing inSimAnnealParams
                                        then do
                                            postProcessNetworkAdd
                                                inGS
                                                inData
                                                maxNetEdges
                                                numToKeep
                                                counter
                                                returnMutated
                                                doSteepest
                                                doRandomOrder
                                                (curBestGraphList, curBestGraphCost)
                                                (newGraphList, newGraphCost)
                                                (tail randIntList)
                                                inSimAnnealParams
                                                netNodes
                                                currentCost
                                                (tail inPhyloGraphList)
                                        else -- simulated annealing--needs new SAParams
                                        do
                                            -- trace ("IANE: " <> (show $ method $ fromJust inSimAnnealParams)) (
                                            (saGraphs, saCounter) ←
                                                postProcessNetworkAddSA
                                                    inGS
                                                    inData
                                                    maxNetEdges
                                                    numToKeep
                                                    counter
                                                    returnMutated
                                                    doSteepest
                                                    doRandomOrder
                                                    (curBestGraphList, curBestGraphCost)
                                                    (newGraphList, newGraphCost)
                                                    (tail randIntList)
                                                    newSAParams
                                                    netNodes
                                                    currentCost
                                                    (tail inPhyloGraphList)

                                            -- if want mutated then return
                                            if returnMutated
                                                then do
                                                    return (saGraphs, saCounter)
                                                else -- delete non-minimal edges if any
                                                -- not sim anneal/drift regular optimal searching
                                                do
                                                    let annealBestCost = minimum $ fmap snd5 saGraphs
                                                    (bestList', counter') ←
                                                        deleteAllNetEdges'
                                                            inGS
                                                            inData
                                                            maxNetEdges
                                                            numToKeep
                                                            saCounter
                                                            False
                                                            doSteepest
                                                            doRandomOrder
                                                            (saGraphs, annealBestCost)
                                                            (randomIntList $ head randIntList)
                                                            Nothing
                                                            saGraphs
                                                    let bestList = GO.selectGraphs Best numToKeep 0.0 (-1) bestList'
                                                    pure (bestList, counter')


{- | postProcessNetworkAddSA processes simaneal/drift
assumes SAParams are updated during return of graph list above
-}
postProcessNetworkAddSA
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Int
    → Bool
    → Bool
    → Bool
    → ([ReducedPhylogeneticGraph], VertexCost)
    → ([ReducedPhylogeneticGraph], VertexCost)
    → [Int]
    → Maybe SAParams
    → [LG.LNode VertexInfo]
    → VertexCost
    → [ReducedPhylogeneticGraph]
    → PhyG ([ReducedPhylogeneticGraph], Int)
postProcessNetworkAddSA inGS inData maxNetEdges numToKeep counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost) (newGraphList, newGraphCost) randIntList inSimAnnealParams _ _ inPhyloGraphList =
    -- trace ("\t\tNumber of network edges: " <> (show $ length netNodes)) (
    -- this to deal with empty list issues if nothing found
    let (nextNewGraphList, firstNewGraphList) =
            if (not . null) newGraphList
                then (tail newGraphList, [head newGraphList])
                else ([], [])
        graphsToInsert =
            if doSteepest
                then newGraphList
                else take numToKeep $ newGraphList <> inPhyloGraphList
    in  -- always accept if found better
        if newGraphCost < curBestGraphCost
            then do
                logWith LogInfo ("\t-> " <> (show newGraphCost))
                insertAllNetEdges'
                    inGS
                    inData
                    maxNetEdges
                    numToKeep
                    (counter + 1)
                    returnMutated
                    doSteepest
                    doRandomOrder
                    (newGraphList, newGraphCost)
                    randIntList
                    inSimAnnealParams
                    graphsToInsert
            else -- check if hit max change/ cooling steps

                if ((currentStep $ fromJust inSimAnnealParams) >= (numberSteps $ fromJust inSimAnnealParams))
                    || ((driftChanges $ fromJust inSimAnnealParams) >= (driftMaxChanges $ fromJust inSimAnnealParams))
                    then do
                        -- trace ("PPA return: " <> (show (newMinCost, curBestCost)))
                        pure $ (GO.selectGraphs Unique numToKeep 0.0 (-1) (newGraphList <> curBestGraphList), counter)
                    else -- more to do

                        let annealBestCost = min curBestGraphCost newGraphCost
                        in  do
                                insertAllNetEdges'
                                    inGS
                                    inData
                                    maxNetEdges
                                    numToKeep
                                    (counter + 1)
                                    returnMutated
                                    doSteepest
                                    doRandomOrder
                                    (firstNewGraphList <> curBestGraphList, annealBestCost)
                                    randIntList
                                    inSimAnnealParams
                                    (nextNewGraphList <> inPhyloGraphList)


-- )

-- | postProcessNetworkAdd prcesses non-simaneal/drift--so no updating of SAParams
postProcessNetworkAdd
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Int
    → Bool
    → Bool
    → Bool
    → ([ReducedPhylogeneticGraph], VertexCost)
    → ([ReducedPhylogeneticGraph], VertexCost)
    → [Int]
    → Maybe SAParams
    → [LG.LNode VertexInfo]
    → VertexCost
    → [ReducedPhylogeneticGraph]
    → PhyG ([ReducedPhylogeneticGraph], Int)
postProcessNetworkAdd inGS inData maxNetEdges numToKeep counter returnMutated doSteepest doRandomOrder (curBestGraphList, _) (newGraphList, newGraphCost) randIntList inSimAnnealParams _ currentCost inPhyloGraphList =
    -- "steepest style descent" abandons existing list if better cost found
    -- trace ("\t\tNumber of network edges: " <> (show $ length netNodes)) (
    if newGraphCost < currentCost
        then -- check if graph OK--done in insert function

            let --- isCyclicList = filter (== True) $ fmap LG.cyclic $ fmap thd5 newGraphList
                --- hasDupEdges = filter (== True) $ fmap LG.hasDuplicateEdge $ fmap thd5 newGraphList
                graphsToInsert =
                    if doSteepest
                        then do newGraphList
                        else take numToKeep $ newGraphList <> inPhyloGraphList
            in  do
                    logWith LogInfo ("\t-> " <> (show newGraphCost))
                    insertAllNetEdges'
                        inGS
                        inData
                        maxNetEdges
                        numToKeep
                        (counter + 1)
                        returnMutated
                        doSteepest
                        doRandomOrder
                        (newGraphList, newGraphCost)
                        randIntList
                        inSimAnnealParams
                        graphsToInsert
        else -- worse graphs found--go on

            if newGraphCost > currentCost
                then do
                    -- trace ("IANE: Worse")
                    insertAllNetEdges'
                        inGS
                        inData
                        maxNetEdges
                        numToKeep
                        (counter + 1)
                        returnMutated
                        doSteepest
                        doRandomOrder
                        (curBestGraphList, currentCost)
                        randIntList
                        inSimAnnealParams
                        inPhyloGraphList
                else -- equal cost
                -- not sure if should add new graphs to queue to do edge deletion again
                do
                    -- new graph list contains the input graph if equal and filterd unique already in insertAllNetEdges
                    let newCurSameBestList = GO.selectGraphs Unique numToKeep 0.0 (-1) (curBestGraphList <> newGraphList)
                    -- trace ("IANE: same " <> (show $ length (tail inPhyloGraphList)))
                    insertAllNetEdges'
                        inGS
                        inData
                        maxNetEdges
                        numToKeep
                        (counter + 1)
                        returnMutated
                        doSteepest
                        doRandomOrder
                        (newCurSameBestList, currentCost)
                        randIntList
                        inSimAnnealParams
                        inPhyloGraphList


{- | insertEachNetEdge takes a phylogenetic graph and inserts all permissible network edges one at time
and returns unique list of new Phylogenetic Graphs and cost
even if worse--could be used for simulated annealing later
if equal returns unique graph list
-}
insertEachNetEdge
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Int
    → Bool
    → Bool
    → Maybe VertexCost
    → Maybe SAParams
    → ReducedPhylogeneticGraph
    → PhyG ([ReducedPhylogeneticGraph], VertexCost, Maybe SAParams)
insertEachNetEdge inGS inData rSeed maxNetEdges numToKeep doSteepest doRandomOrder preDeleteCost inSimAnnealParams inPhyloGraph =
    if LG.isEmpty $ fst5 inPhyloGraph
        then error "Empty input insertEachNetEdge graph in deleteAllNetEdges"
        else
            let currentCost =
                    if isNothing preDeleteCost
                        then snd5 inPhyloGraph
                        else fromJust preDeleteCost

                (_, _, _, netNodes) = LG.splitVertexList (thd5 inPhyloGraph)

                -- parallel stuff
                action ∷ (LG.LEdge b, LG.LEdge b) → PhyG ReducedPhylogeneticGraph
                action = insertNetEdge inGS inData inPhyloGraph preDeleteCost
            in  do
                    candidateNetworkEdgeList' ← getPermissibleEdgePairs inGS (thd5 inPhyloGraph)

                    -- radomize pair list
                    let rSeedList = randomIntList rSeed
                    let candidateNetworkEdgeList =
                            if doRandomOrder
                                then permuteList (head rSeedList) candidateNetworkEdgeList'
                                else candidateNetworkEdgeList'

                    -- newGraphList = concat (fmap (insertNetEdgeBothDirections inGS inData inPhyloGraph) candidateNetworkEdgeList `using`  PU.myParListChunkRDS)
                    inNetEdRList ←
                        insertNetEdgeRecursive
                            inGS
                            inData
                            (tail rSeedList)
                            maxNetEdges
                            doSteepest
                            doRandomOrder
                            inPhyloGraph
                            preDeleteCost
                            inSimAnnealParams
                            candidateNetworkEdgeList

                    actionPar ← getParallelChunkTraverse
                    inNetEdRListMAP ← actionPar action candidateNetworkEdgeList
                    -- mapM (insertNetEdge inGS inData inPhyloGraph preDeleteCost) candidateNetworkEdgeList
                    let (newGraphList, newSAParams) =
                            if not doSteepest
                                then
                                    let genNewSimAnnealParams =
                                            if isNothing inSimAnnealParams
                                                then Nothing
                                                else U.incrementSimAnnealParams inSimAnnealParams
                                    in  -- TODO
                                        (filter (/= emptyReducedPhylogeneticGraph) inNetEdRListMAP, genNewSimAnnealParams)
                                else inNetEdRList
                    let minCost =
                            if null candidateNetworkEdgeList || null newGraphList
                                then infinity
                                else minimum $ fmap snd5 newGraphList

                    logWith LogInfo ("\tExamining at most " <> (show $ length candidateNetworkEdgeList) <> " candidate edge pairs" <> "\n")

                    -- no network edges to insert
                    -- trace ("IENE: " <> (show minCost)) (
                    if (length netNodes >= maxNetEdges)
                        then do
                            logWith LogInfo ("Maximum number of network edges reached: " <> (show $ length netNodes) <> "\n")
                            pure ([inPhyloGraph], snd5 inPhyloGraph, inSimAnnealParams)
                        else -- no edges to add

                            if null candidateNetworkEdgeList
                                then do
                                    -- trace ("IENE num cand edges:" <> (show $ length candidateNetworkEdgeList))
                                    pure ([inPhyloGraph], currentCost, newSAParams)
                                else -- single if steepest so no need to unique

                                    if doSteepest
                                        then do
                                            --  trace ("IENE: All " <> (show minCost))
                                            pure (GO.selectGraphs Best numToKeep 0.0 (-1) $ newGraphList, minCost, newSAParams)
                                        else -- "all" option needs to recurse since does all available edges at each step
                                        -- logic is here since not in the deleteNetEdge function

                                            if isNothing inSimAnnealParams
                                                then
                                                    let -- parallel stuff
                                                        insertAction
                                                            ∷ (Int, Maybe SAParams, ReducedPhylogeneticGraph) → PhyG ([ReducedPhylogeneticGraph], VertexCost, Maybe SAParams)
                                                        insertAction = insertEachNetEdge' inGS inData maxNetEdges numToKeep doSteepest doRandomOrder preDeleteCost
                                                    in  if minCost < currentCost
                                                            then do
                                                                let annealParamList = U.generateUniqueRandList (length newGraphList) newSAParams
                                                                let allRandIntList = take (length newGraphList) (randomIntList (rSeedList !! 1))
                                                                -- TODO
                                                                -- (allGraphListList, costList, allSAParamList) = unzip3 $ PU.seqParMap (parStrategy $ lazyParStrat inGS)  (insertEachNetEdge' inGS inData maxNetEdges numToKeep doSteepest doRandomOrder preDeleteCost) (zip3 allRandIntList annealParamList newGraphList)

                                                                insertPar ← getParallelChunkTraverse
                                                                insertResult ← insertPar insertAction (zip3 allRandIntList annealParamList newGraphList)
                                                                -- mapM  (insertEachNetEdge' inGS inData maxNetEdges numToKeep doSteepest doRandomOrder preDeleteCost) (zip3 allRandIntList annealParamList newGraphList)
                                                                let (allGraphListList, costList, allSAParamList) = unzip3 insertResult
                                                                let (allMinCost, allMinCostGraphs) =
                                                                        if (not . null . concat) allGraphListList
                                                                            then (minimum costList, GO.selectGraphs Unique numToKeep 0.0 (-1) $ concat allGraphListList)
                                                                            else (infinity, [])

                                                                pure (allMinCostGraphs, allMinCost, U.incrementSimAnnealParams $ head allSAParamList)
                                                            else do
                                                                pure (GO.selectGraphs Unique numToKeep 0.0 (-1) $ newGraphList, minCost, newSAParams)
                                                else -- SA anneal/Drift

                                                -- always take better

                                                    if minCost < currentCost
                                                        then do
                                                            pure (newGraphList, minCost, newSAParams)
                                                        else -- check if hit step limit--more for SA than drift

                                                            if ((currentStep $ fromJust inSimAnnealParams) >= (numberSteps $ fromJust inSimAnnealParams))
                                                                || ((driftChanges $ fromJust inSimAnnealParams) >= (driftMaxChanges $ fromJust inSimAnnealParams))
                                                                then do
                                                                    pure ([inPhyloGraph], snd5 inPhyloGraph, inSimAnnealParams)
                                                                else -- otherwise do the anneal/Drift accept, or keep going on input graph

                                                                    let (acceptGraph, nextSAParams) = U.simAnnealAccept inSimAnnealParams currentCost minCost
                                                                    in  if acceptGraph
                                                                            then do
                                                                                pure (newGraphList, minCost, newSAParams)
                                                                            else do
                                                                                insertEachNetEdge
                                                                                    inGS
                                                                                    inData
                                                                                    (head $ randomIntList rSeed)
                                                                                    maxNetEdges
                                                                                    numToKeep
                                                                                    doSteepest
                                                                                    doRandomOrder
                                                                                    preDeleteCost
                                                                                    nextSAParams
                                                                                    inPhyloGraph


-- | insertEachNetEdge' is a wrapper around insertEachNetEdge to allow for parmapping with multiple parameters
insertEachNetEdge'
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Bool
    → Bool
    → Maybe VertexCost
    → (Int, Maybe SAParams, ReducedPhylogeneticGraph)
    → PhyG ([ReducedPhylogeneticGraph], VertexCost, Maybe SAParams)
insertEachNetEdge' inGS inData maxNetEdges numToKeep doSteepest doRandomOrder preDeleteCost (rSeed, inSimAnnealParams, inPhyloGraph) =
    insertEachNetEdge inGS inData rSeed maxNetEdges numToKeep doSteepest doRandomOrder preDeleteCost inSimAnnealParams inPhyloGraph


{- | insertNetEdgeRecursive recursively inserts edges and returns new graph only if better
if parallel evaluated numThreads each time (steepest scenario)
-}
insertNetEdgeRecursive
    ∷ GlobalSettings
    → ProcessedData
    → [Int]
    → Int
    → Bool
    → Bool
    → ReducedPhylogeneticGraph
    → Maybe VertexCost
    → Maybe SAParams
    → [(LG.LEdge EdgeInfo, LG.LEdge EdgeInfo)]
    → PhyG ([ReducedPhylogeneticGraph], Maybe SAParams)
insertNetEdgeRecursive inGS inData rSeedList maxNetEdges doSteepest doRandomOrder inPhyloGraph preDeleteCost inSimAnnealParams inEdgePairList =
    -- trace ("Edges pairs to go : " <> (show $ length edgePairList)) (
    if null inEdgePairList
        then do
            pure ([inPhyloGraph], inSimAnnealParams)
        else -- don't want to over saturate the parallel thread system

            let {-saRounds = if isNothing inSimAnnealParams then 1
                           else rounds $ fromJust inSimAnnealParams
                (numGraphsToExamine, _) = divMod PU.getNumThreads saRounds -- this may not "drift" if finds alot better, but that's how its supposed to work
                -}

                numGraphsToExamine = graphsSteepest inGS -- min (graphsSteepest inGS) PU.getNumThreads
                -- firstEdgePair = head edgePairList
                edgePairList = take numGraphsToExamine inEdgePairList

                -- check for max net edges
                (_, _, _, netNodes) = LG.splitVertexList (thd5 inPhyloGraph)

                -- parallel seup
                action ∷ (LG.LEdge b, LG.LEdge b) → PhyG ReducedPhylogeneticGraph
                action = insertNetEdge inGS inData inPhyloGraph preDeleteCost
            in  do
                    -- need to check display/character trees not conical graph
                    -- newGraph = insertNetEdge inGS inData leafGraph inPhyloGraph preDeleteCost firstEdgePair
                    -- these graph costs are "exact" or at least non-heuristic--needs to be updated when get a good heuristic
                    -- TODO
                    -- newGraphList'' = PU.seqParMap (parStrategy $ lazyParStrat inGS) (insertNetEdge inGS inData inPhyloGraph preDeleteCost) edgePairList
                    actionPar ← getParallelChunkTraverse
                    newGraphList'' ← actionPar action edgePairList
                    -- mapM (insertNetEdge inGS inData inPhyloGraph preDeleteCost) edgePairList
                    let newGraphList' = filter (/= emptyReducedPhylogeneticGraph) newGraphList''
                    let newGraphList = GO.selectGraphs Best (maxBound ∷ Int) 0.0 (-1) newGraphList'
                    let newGraphCost = snd5 $ head newGraphList

                    -- traceNoLF ("*")  (      -- trace ("INER: " <> (show $ snd5 newGraph) <> " " <> (show preDeleteCost)) (
                    if length netNodes >= maxNetEdges
                        then do
                            logWith LogInfo ("Maximum number of network edges reached: " <> (show $ length netNodes) <> "\n")
                            pure ([inPhyloGraph], inSimAnnealParams)
                        else -- malformed graph--returns nothing for either regular or simAnneal/drift

                            if null newGraphList'
                                then do
                                    -- trace ("INER: Empty more to go : " <> (show $ length $ tail edgePairList))
                                    insertNetEdgeRecursive
                                        inGS
                                        inData
                                        rSeedList
                                        maxNetEdges
                                        doSteepest
                                        doRandomOrder
                                        inPhyloGraph
                                        preDeleteCost
                                        inSimAnnealParams
                                        (drop numGraphsToExamine inEdgePairList)
                                else -- "regular" insert, within steepest

                                    if isNothing inSimAnnealParams
                                        then -- better cost

                                            if newGraphCost < snd5 inPhyloGraph
                                                then do
                                                    -- cyclic check in insert edge function
                                                    -- trace ("INER: Better -> " <> (show $ snd5 newGraph))
                                                    pure (newGraphList, inSimAnnealParams)
                                                else -- not better
                                                do
                                                    -- trace ("INER: Really Not Better")
                                                    insertNetEdgeRecursive
                                                        inGS
                                                        inData
                                                        rSeedList
                                                        maxNetEdges
                                                        doSteepest
                                                        doRandomOrder
                                                        inPhyloGraph
                                                        preDeleteCost
                                                        inSimAnnealParams
                                                        (drop numGraphsToExamine inEdgePairList)
                                        else -- sim annealing/drift

                                        -- trace ("IENR:" <> (show (newGraphCost, snd5 inPhyloGraph)) <> " params: " <> (show (currentStep $ fromJust inSimAnnealParams, numberSteps $ fromJust inSimAnnealParams, driftChanges $ fromJust inSimAnnealParams, driftMaxChanges $ fromJust inSimAnnealParams))) (
                                        -- if better always accept

                                            if newGraphCost < snd5 inPhyloGraph
                                                then -- cyclic check in insert edge function
                                                -- trace ("INER: Better -> " <> (show $ snd5 newGraph))
                                                -- these graph costs are "exact" or at least non-heuristic--needs to be updated when get a good heuristic

                                                    let (_, nextSAParams) = U.simAnnealAccept inSimAnnealParams (snd5 inPhyloGraph) newGraphCost
                                                    in  do
                                                            pure (newGraphList, nextSAParams)
                                                else -- check if hit step limit--more for SA than drift

                                                    if ((currentStep $ fromJust inSimAnnealParams) >= (numberSteps $ fromJust inSimAnnealParams))
                                                        || ((driftChanges $ fromJust inSimAnnealParams) >= (driftMaxChanges $ fromJust inSimAnnealParams))
                                                        then do
                                                            pure ([inPhyloGraph], inSimAnnealParams)
                                                        else -- otherwise do the anneal/Drift accept

                                                            let (acceptGraph, nextSAParams) = U.simAnnealAccept inSimAnnealParams (snd5 inPhyloGraph) newGraphCost
                                                            in  if acceptGraph
                                                                    then do
                                                                        pure (newGraphList, nextSAParams)
                                                                    else do
                                                                        insertNetEdgeRecursive
                                                                            inGS
                                                                            inData
                                                                            rSeedList
                                                                            maxNetEdges
                                                                            doSteepest
                                                                            doRandomOrder
                                                                            inPhyloGraph
                                                                            preDeleteCost
                                                                            nextSAParams
                                                                            (drop numGraphsToExamine inEdgePairList)


-- )
-- )

{- | insertNetEdge inserts an edge between two other edges, creating 2 new nodes and rediagnoses graph
contacts deletes 2 orginal edges and adds 2 nodes and 5 new edges
does not check any edge reasonable-ness properties
new edge directed from first to second edge
naive for now
predeletecost of edge move
no choice of graph--just makes and returns
-}
insertNetEdge
    ∷ GlobalSettings
    → ProcessedData
    → ReducedPhylogeneticGraph
    → Maybe VertexCost
    → (LG.LEdge b, LG.LEdge b)
    → PhyG ReducedPhylogeneticGraph
insertNetEdge inGS inData inPhyloGraph _ edgePair@((u, v, _), (u', v', _)) =
    if LG.isEmpty $ thd5 inPhyloGraph
        then error "Empty input phylogenetic graph in insNetEdge"
        else
            let inSimple = fst5 inPhyloGraph

                -- get children of u' to make sure no net children--moved to permissiable edges
                -- u'ChildrenNetNodes = filter (== True) $ fmap (LG.isNetworkNode inSimple) $ LG.descendants inSimple u'

                numNodes = length $ LG.nodes inSimple
                newNodeOne = (numNodes, TL.pack ("HTU" <> (show numNodes)))
                newNodeTwo = (numNodes + 1, TL.pack ("HTU" <> (show $ numNodes + 1)))
                newEdgeList =
                    [ (u, fst newNodeOne, 0.0)
                    , (fst newNodeOne, v, 0.0)
                    , (u', fst newNodeTwo, 0.0)
                    , (fst newNodeTwo, v', 0.0)
                    , (fst newNodeOne, fst newNodeTwo, 0.0)
                    ]
                edgesToDelete = [(u, v), (u', v')]
                newSimple = LG.delEdges edgesToDelete $ LG.insEdges newEdgeList $ LG.insNodes [newNodeOne, newNodeTwo] inSimple

                -- do not prune other edges if now unused
                pruneEdges = False

                -- don't warn that edges are being pruned
                warnPruneEdges = False

                -- graph optimization from root
                startVertex = Nothing

                -- full two-pass optimization
                leafGraph = LG.extractLeafGraph $ thd5 inPhyloGraph
            in  do
                    newPhyloGraph ← T.multiTraverseFullyLabelSoftWiredReduced inGS inData pruneEdges warnPruneEdges leafGraph startVertex newSimple

                    -- calculates heursitic graph delta
                    -- (heuristicDelta, _, _, _, _)  = heuristicAddDelta inGS inPhyloGraph edgePair (fst newNodeOne) (fst newNodeTwo)
                    let heuristicDelta' = heuristicAddDelta' inGS inPhyloGraph edgePair

                    let edgeAddDelta = deltaPenaltyAdjustment inGS inPhyloGraph "add"

                    let heuristicFactor = (heuristicDelta' + edgeAddDelta) / edgeAddDelta

                    -- use or not Net add heuristics
                    let metHeuristicThreshold = not (useNetAddHeuristic inGS) || heuristicFactor < (2 / 3)

                    -- remove these checks when working
                    isPhyloGraph <- LG.isPhylogeneticGraph newSimple
                    if not isPhyloGraph
                        then do
                            pure emptyReducedPhylogeneticGraph
                        else
                            if metHeuristicThreshold
                                then -- if (GO.parentsInChainGraph . thd5) newPhyloGraph then emptyPhylogeneticGraph
                                -- else

                                    if (snd5 newPhyloGraph <= snd5 inPhyloGraph)
                                        then do
                                            pure newPhyloGraph
                                        else do
                                            pure emptyReducedPhylogeneticGraph
                                else do
                                    pure emptyReducedPhylogeneticGraph


-- | (curBestGraphList, annealBestCost) is a wrapper for moveAllNetEdges' allowing for multiple simulated annealing rounds
deleteAllNetEdges
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Int
    → Int
    → Bool
    → Bool
    → Bool
    → ([ReducedPhylogeneticGraph], VertexCost)
    → (Maybe SAParams, [ReducedPhylogeneticGraph])
    → PhyG ([ReducedPhylogeneticGraph], Int)
deleteAllNetEdges inGS inData rSeed maxNetEdges numToKeep counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost) (inSimAnnealParams, inPhyloGraphList) =
    if isNothing inSimAnnealParams
        then
            deleteAllNetEdges'
                inGS
                inData
                maxNetEdges
                numToKeep
                counter
                returnMutated
                doSteepest
                doRandomOrder
                (curBestGraphList, curBestGraphCost)
                (randomIntList rSeed)
                inSimAnnealParams
                inPhyloGraphList
        else
            let -- create list of params with unique list of random values for rounds of annealing
                annealingRounds = rounds $ fromJust inSimAnnealParams
                annealParamGraphList = U.generateUniqueRandList annealingRounds inSimAnnealParams
                replicateRandIntList = fmap randomIntList (take annealingRounds (randomIntList rSeed))

                -- parallel
                action ∷ ([Int], Maybe SAParams, [ReducedPhylogeneticGraph]) → PhyG ([ReducedPhylogeneticGraph], Int)
                action =
                    deleteAllNetEdges''
                        inGS
                        inData
                        maxNetEdges
                        numToKeep
                        counter
                        returnMutated
                        doSteepest
                        doRandomOrder
                        (curBestGraphList, curBestGraphCost)
            in  do
                    -- TODO
                    actionPar ← getParallelChunkTraverse
                    deleteResult ← actionPar action (zip3 replicateRandIntList annealParamGraphList (replicate annealingRounds inPhyloGraphList))
                    -- mapM (deleteAllNetEdges'' inGS inData maxNetEdges numToKeep counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost)) (zip3 replicateRandIntList annealParamGraphList (replicate annealingRounds inPhyloGraphList))
                    -- (annealRoundsList, counterList) = unzip (PU.seqParMap (parStrategy $ lazyParStrat inGS) (deleteAllNetEdges'' inGS inData maxNetEdges numToKeep counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost)) (zip3 replicateRandIntList annealParamGraphList (replicate annealingRounds inPhyloGraphList)))
                    let (annealRoundsList, counterList) = unzip deleteResult
                    pure (GO.selectGraphs Best numToKeep 0.0 (-1) (concat annealRoundsList), sum counterList)


-- | deleteAllNetEdges'' is a wrapper around deleteAllNetEdges' to allow use of seqParMap
deleteAllNetEdges''
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Int
    → Bool
    → Bool
    → Bool
    → ([ReducedPhylogeneticGraph], VertexCost)
    → ([Int], Maybe SAParams, [ReducedPhylogeneticGraph])
    → PhyG ([ReducedPhylogeneticGraph], Int)
deleteAllNetEdges'' inGS inData maxNetEdges numToKeep counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost) (randIntList, inSimAnnealParams, inPhyloGraphList) =
    deleteAllNetEdges'
        inGS
        inData
        maxNetEdges
        numToKeep
        counter
        returnMutated
        doSteepest
        doRandomOrder
        (curBestGraphList, curBestGraphCost)
        randIntList
        inSimAnnealParams
        inPhyloGraphList


{- | deleteAllNetEdges deletes network edges one each each round until no better or additional
graphs are found
call with ([], infinity) [single input graph]
-}
deleteAllNetEdges'
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Int
    → Bool
    → Bool
    → Bool
    → ([ReducedPhylogeneticGraph], VertexCost)
    → [Int]
    → Maybe SAParams
    → [ReducedPhylogeneticGraph]
    → PhyG ([ReducedPhylogeneticGraph], Int)
deleteAllNetEdges' inGS inData maxNetEdges numToKeep counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost) randIntList inSimAnnealParams inPhyloGraphList =
    -- trace ("In deleteAllNetEdges " <> (show $ length inPhyloGraphList)) (
    if null inPhyloGraphList
        then do
            pure (take numToKeep curBestGraphList, counter)
        else
            if LG.isEmpty (fst5 $ head inPhyloGraphList)
                then do
                    deleteAllNetEdges'
                        inGS
                        inData
                        maxNetEdges
                        numToKeep
                        counter
                        returnMutated
                        doSteepest
                        doRandomOrder
                        (curBestGraphList, curBestGraphCost)
                        randIntList
                        inSimAnnealParams
                        (tail inPhyloGraphList)
                else do
                    let currentCost = min curBestGraphCost (snd5 $ head inPhyloGraphList)

                    (newGraphList', _, newSAParams) ←
                        deleteEachNetEdge
                            inGS
                            inData
                            (head randIntList)
                            numToKeep
                            doSteepest
                            doRandomOrder
                            False
                            inSimAnnealParams
                            (head inPhyloGraphList)

                    let newGraphList = GO.selectGraphs Best numToKeep 0.0 (-1) newGraphList'
                    let newGraphCost =
                            if (not . null) newGraphList
                                then snd5 $ head newGraphList
                                else infinity

                    -- trace ("DANE: " <> (show (newGraphCost, length newGraphList))) (
                    -- if graph is a tree no edges to delete
                    if LG.isTree (fst5 $ head inPhyloGraphList)
                        then do
                            -- let (a,b,c,d) = LG.splitVertexList (fst5 $ head inPhyloGraphList)
                            -- in
                            logWith LogInfo ("\tGraph in delete network edges is tree--skipping" <> "\n") --  :" <> (show $ (snd5 $ head inPhyloGraphList, length a, length b, length c, length d)))
                            deleteAllNetEdges'
                                inGS
                                inData
                                maxNetEdges
                                numToKeep
                                (counter + 1)
                                returnMutated
                                doSteepest
                                doRandomOrder
                                ((head inPhyloGraphList) : curBestGraphList, currentCost)
                                (tail randIntList)
                                inSimAnnealParams
                                (tail inPhyloGraphList)
                        else -- is this an issue for SA?

                            if null newGraphList
                                then do
                                    pure (take numToKeep curBestGraphList, counter + 1)
                                else -- regular delete wihtout simulated annealing

                                    if isNothing inSimAnnealParams
                                        then do
                                            postProcessNetworkDelete
                                                inGS
                                                inData
                                                maxNetEdges
                                                numToKeep
                                                counter
                                                returnMutated
                                                doSteepest
                                                doRandomOrder
                                                (curBestGraphList, curBestGraphCost)
                                                (tail randIntList)
                                                inSimAnnealParams
                                                inPhyloGraphList
                                                newGraphList
                                                newGraphCost
                                                currentCost
                                        else -- simulated annealing
                                        do
                                            (saGraphs, saCounter) ←
                                                postProcessNetworkDeleteSA
                                                    inGS
                                                    inData
                                                    maxNetEdges
                                                    numToKeep
                                                    counter
                                                    returnMutated
                                                    doSteepest
                                                    doRandomOrder
                                                    (curBestGraphList, curBestGraphCost)
                                                    (tail randIntList)
                                                    newSAParams
                                                    inPhyloGraphList
                                                    newGraphList
                                                    newGraphCost
                                                    currentCost

                                            -- if want mutated then return
                                            if returnMutated
                                                then do
                                                    pure (saGraphs, saCounter)
                                                else -- insert non-minimal edges if any
                                                -- not sim anneal/drift regular optimal searching
                                                do
                                                    let annealBestCost = minimum $ fmap snd5 saGraphs
                                                    insertedGraphs ←
                                                        insertAllNetEdges'
                                                            inGS
                                                            inData
                                                            maxNetEdges
                                                            numToKeep
                                                            saCounter
                                                            False
                                                            doSteepest
                                                            doRandomOrder
                                                            (saGraphs, annealBestCost)
                                                            (randomIntList $ head randIntList)
                                                            Nothing
                                                            saGraphs
                                                    let (bestList', counter') = insertedGraphs
                                                    let bestList = GO.selectGraphs Best numToKeep 0.0 (-1) bestList'

                                                    pure (bestList, counter')


{- | postProcessNetworkDeleteSA postprocesses results from delete actions for non-annealing/Drift network delete operations
assumes SAParams are updated during return of graph list above
-}
postProcessNetworkDeleteSA
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Int
    → Bool
    → Bool
    → Bool
    → ([ReducedPhylogeneticGraph], VertexCost)
    → [Int]
    → Maybe SAParams
    → [ReducedPhylogeneticGraph]
    → [ReducedPhylogeneticGraph]
    → VertexCost
    → VertexCost
    → PhyG ([ReducedPhylogeneticGraph], Int)
postProcessNetworkDeleteSA inGS inData maxNetEdges numToKeep counter returnMutated doSteepest doRandomOrder (curBestGraphList, curBestGraphCost) randIntList inSimAnnealParams inPhyloGraphList newGraphList newGraphCost currentCost =
    -- this to deal with empty list issues if nothing found
    let (nextNewGraphList, firstNewGraphList) =
            if (not . null) newGraphList
                then (tail newGraphList, [head newGraphList])
                else ([], [])
        graphsToDelete =
            if doSteepest
                then newGraphList
                else take numToKeep $ newGraphList <> inPhyloGraphList
    in  -- always accept if found better
        if newGraphCost < currentCost
            then do
                logWith LogInfo ("\t-> " <> (show newGraphCost))
                deleteAllNetEdges'
                    inGS
                    inData
                    maxNetEdges
                    numToKeep
                    (counter + 1)
                    returnMutated
                    doSteepest
                    doRandomOrder
                    (newGraphList, newGraphCost)
                    randIntList
                    inSimAnnealParams
                    graphsToDelete
            else -- check if hit max change/ cooling steps

                if ((currentStep $ fromJust inSimAnnealParams) >= (numberSteps $ fromJust inSimAnnealParams))
                    || ((driftChanges $ fromJust inSimAnnealParams) >= (driftMaxChanges $ fromJust inSimAnnealParams))
                    then do
                        -- trace ("PPA return: " <> (show (newMinCost, curBestCost)))
                        pure (GO.selectGraphs Unique numToKeep 0.0 (-1) (newGraphList <> curBestGraphList), counter)
                    else -- more to do

                        let annealBestCost = min curBestGraphCost newGraphCost
                        in  do
                                deleteAllNetEdges'
                                    inGS
                                    inData
                                    maxNetEdges
                                    numToKeep
                                    (counter + 1)
                                    returnMutated
                                    doSteepest
                                    doRandomOrder
                                    (firstNewGraphList <> curBestGraphList, annealBestCost)
                                    randIntList
                                    inSimAnnealParams
                                    (nextNewGraphList <> inPhyloGraphList)


-- | postProcessNetworkDelete postprocesses results from delete actions for "regular" ie non-annealing/Drift network delete operations
postProcessNetworkDelete
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Int
    → Bool
    → Bool
    → Bool
    → ([ReducedPhylogeneticGraph], VertexCost)
    → [Int]
    → Maybe SAParams
    → [ReducedPhylogeneticGraph]
    → [ReducedPhylogeneticGraph]
    → VertexCost
    → VertexCost
    → PhyG ([ReducedPhylogeneticGraph], Int)
postProcessNetworkDelete inGS inData maxNetEdges numToKeep counter returnMutated doSteepest doRandomOrder (curBestGraphList, _) randIntList inSimAnnealParams inPhyloGraphList newGraphList newGraphCost currentCost =
    -- worse graphs found--go on
    if newGraphCost > currentCost
        then do
            deleteAllNetEdges'
                inGS
                inData
                maxNetEdges
                numToKeep
                (counter + 1)
                returnMutated
                doSteepest
                doRandomOrder
                ((head inPhyloGraphList) : curBestGraphList, currentCost)
                randIntList
                inSimAnnealParams
                (tail inPhyloGraphList)
        else -- "steepest style descent" abandons existing list if better cost found

            if newGraphCost < currentCost
                then do
                    logWith LogInfo ("\t-> " <> (show newGraphCost))
                    if doSteepest
                        then do
                            deleteAllNetEdges'
                                inGS
                                inData
                                maxNetEdges
                                numToKeep
                                (counter + 1)
                                returnMutated
                                doSteepest
                                doRandomOrder
                                (newGraphList, newGraphCost)
                                randIntList
                                inSimAnnealParams
                                newGraphList
                        else do
                            deleteAllNetEdges'
                                inGS
                                inData
                                maxNetEdges
                                numToKeep
                                (counter + 1)
                                returnMutated
                                doSteepest
                                doRandomOrder
                                (newGraphList, newGraphCost)
                                randIntList
                                inSimAnnealParams
                                (newGraphList <> (tail inPhyloGraphList))
                else -- equal cost
                -- not sure if should add new graphs to queue to do edge deletion again

                -- new graph list contains the input graph if equal and filterd unique already in deleteEachNetEdge

                    let newCurSameBestList = GO.selectGraphs Unique numToKeep 0.0 (-1) (curBestGraphList <> newGraphList)
                    in  do
                            deleteAllNetEdges'
                                inGS
                                inData
                                maxNetEdges
                                numToKeep
                                (counter + 1)
                                returnMutated
                                doSteepest
                                doRandomOrder
                                (newCurSameBestList, currentCost)
                                randIntList
                                inSimAnnealParams
                                (tail inPhyloGraphList)


-- | deleteOneNetAddAll' wrapper on deleteOneNetAddAll to allow for parmap
deleteOneNetAddAll'
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Bool
    → Bool
    → ReducedPhylogeneticGraph
    → Int
    → Maybe SAParams
    → LG.Edge
    → PhyG [ReducedPhylogeneticGraph]
deleteOneNetAddAll' inGS inData maxNetEdges numToKeep doSteepest doRandomOrder inPhyloGraph rSeed inSimAnnealParams edgeToDelete =
    deleteOneNetAddAll
        inGS
        inData
        maxNetEdges
        numToKeep
        doSteepest
        doRandomOrder
        inPhyloGraph
        [edgeToDelete]
        rSeed
        inSimAnnealParams


{- | deleteOneNetAddAll version deletes net edges in turn and readds-based on original cost
but this cost in graph (really not correct) but allows logic of insert edge to function better
unlike deleteOneNetAddAll' only deals with single edge deletion at a time
-}
deleteOneNetAddAll
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Bool
    → Bool
    → ReducedPhylogeneticGraph
    → [LG.Edge]
    → Int
    → Maybe SAParams
    → PhyG [ReducedPhylogeneticGraph]
deleteOneNetAddAll inGS inData maxNetEdges numToKeep doSteepest doRandomOrder inPhyloGraph edgeToDeleteList rSeed inSimAnnealParams =
    if null edgeToDeleteList
        then do
            -- trace ("\tGraph has no edges to move---skipping")
            pure [inPhyloGraph]
        else
            if LG.isEmpty $ thd5 inPhyloGraph
                then error "Empty graph in deleteOneNetAddAll"
                else do
                    -- trace ("DONAA-New: " <> (show $ snd5 inPhyloGraph) <> " Steepest:" <> (show doSteepest)) (
                    logWith
                        LogInfo
                        ("Moving " <> (show $ length edgeToDeleteList) <> " network edges, current best cost: " <> (show $ snd5 inPhyloGraph) <> "\n")
                    -- start with initial graph cost
                    let inGraphCost = snd5 inPhyloGraph

                    -- get deleted simple graphs and bool for changed
                    delGraphBoolPair ← deleteNetworkEdge (fst5 inPhyloGraph) (head edgeToDeleteList)

                    -- no change in network structure
                    if snd delGraphBoolPair == False
                        then do
                            deleteOneNetAddAll
                                inGS
                                inData
                                maxNetEdges
                                numToKeep
                                doSteepest
                                doRandomOrder
                                inPhyloGraph
                                (tail edgeToDeleteList)
                                rSeed
                                inSimAnnealParams
                        else
                            let simpleGraphToInsert = fst delGraphBoolPair

                                (_, _, _, curNetNodes) = LG.splitVertexList simpleGraphToInsert
                                curNumNetNodes = length curNetNodes

                                -- optimize deleted graph and update cost with input cost
                                leafGraph = LG.extractLeafGraph $ thd5 inPhyloGraph
                            in  do
                                    graphToInsert ← T.multiTraverseFullyLabelSoftWiredReduced inGS inData False False leafGraph Nothing simpleGraphToInsert -- `using` PU.myParListChunkRDS

                                    -- keep same cost and just keep better--check if better than original later
                                    let graphToInsert' = T.updatePhylogeneticGraphCostReduced graphToInsert inGraphCost

                                    insertedGraphTripleList ←
                                        insertEachNetEdge
                                            inGS
                                            inData
                                            rSeed
                                            (curNumNetNodes + 1)
                                            numToKeep
                                            doSteepest
                                            doRandomOrder
                                            Nothing
                                            inSimAnnealParams
                                            graphToInsert'

                                    let newMinimumCost = snd3 insertedGraphTripleList

                                    let newBestGraphs = filter ((== newMinimumCost) . snd5) $ fst3 insertedGraphTripleList

                                    -- trace ("DONAA-New: " <> (show (inGraphCost, fmap snd5 graphsToInsert, fmap snd5 graphsToInsert', newMinimumCost))) (
                                    if newMinimumCost < inGraphCost
                                        then do
                                            -- trace ("DONA-> ")
                                            pure newBestGraphs
                                        else do
                                            deleteOneNetAddAll
                                                inGS
                                                inData
                                                maxNetEdges
                                                numToKeep
                                                doSteepest
                                                doRandomOrder
                                                inPhyloGraph
                                                (tail edgeToDeleteList)
                                                rSeed
                                                inSimAnnealParams


{- | getPermissibleEdgePairs takes a DecoratedGraph and returns the list of all pairs
of edges that can be joined by a network edge and meet all necessary conditions
-}

-- add in other conditions
--   reproducable--ie not tree noide with two net node children--other stuff
getPermissibleEdgePairs ∷ GlobalSettings → DecoratedGraph → PhyG [(LG.LEdge EdgeInfo, LG.LEdge EdgeInfo)]
getPermissibleEdgePairs inGS inGraph =
    if LG.isEmpty inGraph
        then error "Empty input graph in isEdgePairPermissible"
        else
            let edgeList = LG.labEdges inGraph

                -- edges to potentially conenct
                edgePairs = cartProd edgeList edgeList

                -- get coeval node pairs in existing grap
                coevalNodeConstraintList = LG.coevalNodePairs inGraph

                -- parallel
                -- action :: (LNode a, LNode a) -> (LNode a, LNode a, [LNode a], [LNode a], [LNode a], [LNode a])
                action = LG.addBeforeAfterToPair inGraph
            in  do
                    actionPar ← getParallelChunkMap
                    let coevalNodeConstraintList' = actionPar action coevalNodeConstraintList
                    -- PU.seqParMap (parStrategy $ lazyParStrat inGS) (LG.addBeforeAfterToPair inGraph) coevalNodeConstraintList -- `using`  PU.myParListChunkRDS

                    -- edgeAction :: (LG.LEdge EdgeInfo, LG.LEdge EdgeInfo) -> Bool
                    let edgeAction = isEdgePairPermissible inGraph coevalNodeConstraintList'
                    edgePar ← getParallelChunkMap
                    let edgeTestList = edgePar edgeAction edgePairs
                    -- PU.seqParMap (parStrategy $ lazyParStrat inGS) (isEdgePairPermissible inGraph coevalNodeConstraintList') edgePairs -- `using`  PU.myParListChunkRDS

                    let pairList = fmap fst $ filter ((== True) . snd) $ zip edgePairs edgeTestList

                    -- trace ("Edge Pair list :" <> (show $ fmap f pairList) <> "\n"
                    --  <> "GPEP\n" <> (LG.prettify $ GO.convertDecoratedToSimpleGraph inGraph))
                    pure pairList


-- where f (a, b) = (LG.toEdge a, LG.toEdge b)

{- | isEdgePairPermissible takes a graph and two edges, coeval contraints, and tests whether a
pair of edges can be linked by a new edge and satify three consitions:
   1) neither edge is a network edge
   2) one edge cannot be "before" while the other is "after" in any of the constraint pairs
   3) neither edge is an ancestor or descendent edge of the other (tested via bv of nodes)
the result should apply to a new edge in either direction
new edge to be creted is edge1 -> ege2
Could change to LG.isPhylogeneticGraph
-}
isEdgePairPermissible
    ∷ DecoratedGraph
    → [(LG.LNode a, LG.LNode a, [LG.LNode a], [LG.LNode a], [LG.LNode a], [LG.LNode a])]
    → (LG.LEdge EdgeInfo, LG.LEdge EdgeInfo)
    → Bool
isEdgePairPermissible inGraph constraintList (edge1@(u, v, _), edge2@(u', v', _)) =
    if LG.isEmpty inGraph
        then error "Empty input graph in isEdgePairPermissible"
        else
            if u == u'
                then False
                else
                    if v == v'
                        then False
                        else -- equality implied in above two
                        -- else if LG.toEdge edge1 == LG.toEdge edge2 then False

                            if (LG.isNetworkNode inGraph u) || (LG.isNetworkNode inGraph u')
                                then False
                                else
                                    if (LG.isNetworkLabEdge inGraph edge1) || (LG.isNetworkLabEdge inGraph edge2)
                                        then False
                                        else
                                            if not (LG.meetsAllCoevalConstraintsNodes (fmap removeNodeLabels constraintList) edge1 edge2)
                                                then False
                                                else
                                                    if (isAncDescEdge inGraph edge1 edge2)
                                                        then False
                                                        else -- get children of u' to make sure no net children

                                                            if (not . null) $ filter (== True) $ fmap (LG.isNetworkNode inGraph) $ LG.descendants inGraph u'
                                                                then False
                                                                else True
    where
        removeNodeLabels (a, b, c, d, e, f) = (LG.toNode a, LG.toNode b, fmap LG.toNode c, fmap LG.toNode d, fmap LG.toNode e, fmap LG.toNode f)


{- | isAncDescEdge takes a graph and two edges and examines whethe either edge is the ancestor or descendent of the other
this is done via examination of teh bitvector fields of the node
-}
isAncDescEdge ∷ DecoratedGraph → LG.LEdge EdgeInfo → LG.LEdge EdgeInfo → Bool
isAncDescEdge inGraph (a, _, _) (b, _, _) =
    if LG.isEmpty inGraph
        then error "Empty input graph in isAncDescEdge"
        else
            let aBV = bvLabel $ fromJust $ LG.lab inGraph a
                bBV = bvLabel $ fromJust $ LG.lab inGraph b
            in  -- trace ("IADE: " <> (show (a, aBV, b, bBV, aBV .&. bBV))) (
                if aBV .&. bBV == aBV
                    then True
                    else
                        if aBV .&. bBV == bBV
                            then True
                            else False


--- )

{- These heuristics do not seem tom work well at all-}

{- | heuristic add delta' based on new display tree and delta from existing costs by block--assumming < 0
original edges subtree1 ((u,l),(u,v)) and subtree2 ((u',v'),(u',l')) create a directed edge from
subtree 1 to subtree 2 via
1) Add node x and y, delete edges (u,v) and (u'v') and create edges (u,x), (x,v), (u',y), and (y,v')
2) real cost is the sum of block costs that are lower for new graph versus older
3) heuristic is when new subtree is lower than existing block by block
   so calculate d(u,v) + d(u',v') [existing display tree cost estimate] compared to
   d((union u,v), v') - d(u'.v') [New display tree cost estimate] over blocks
   so blockDelta = if d((union u,v), v') - d(u'.v') < d(u,v) + d(u',v') then d((union u,v), v') - d(u'.v')
                    else 0 [existing better]
   graphDelta = egdeAddDelta (separately calculated) + sum [blockDelta]
   Compare to real delta to check behavior
original subtrees u -> (a,v) and u' -> (v',b)
-}
heuristicAddDelta' ∷ GlobalSettings → ReducedPhylogeneticGraph → (LG.LEdge b, LG.LEdge b) → VertexCost
heuristicAddDelta' _ inPhyloGraph ((u, v, _), (u', v', _)) =
    if LG.isEmpty (fst5 inPhyloGraph)
        then error "Empty graph in heuristicAddDelta"
        else
            let a = head $ filter (/= v) $ LG.descendants (fst5 inPhyloGraph) u
                b = head $ filter (/= v') $ LG.descendants (fst5 inPhyloGraph) u'
                blockTrees =
                    fmap V.fromList $
                        fmap (GO.getDecoratedDisplayTreeList (thd5 inPhyloGraph)) $
                            V.zip (fth5 inPhyloGraph) $
                                V.fromList [0 .. (V.length (fft5 inPhyloGraph) - 1)]
                blockDeltaV = V.zipWith (getBlockDelta (u, v, u', v', a, b)) blockTrees (fft5 inPhyloGraph)
            in  V.sum blockDeltaV


{- | getBlockDelta determines the network add delta for each block (vector of characters)
if existing is lower then zero, else (existing - new)
-}
getBlockDelta
    ∷ (LG.Node, LG.Node, LG.Node, LG.Node, LG.Node, LG.Node) → V.Vector DecoratedGraph → V.Vector CharInfo → VertexCost
getBlockDelta (u, v, u', v', a, b) inCharV charInfoV =
    if V.null inCharV
        then error "Empty charcter tree vector in getBlockDelta"
        else
            let (charNewV, charExistingV) = V.unzip $ V.zipWith (getCharacterDelta (u, v, u', v', a, b)) inCharV charInfoV
                newCost = V.sum charNewV
                existingCost = V.sum charExistingV
            in  -- trace ("GBD: " <> (show (newCost, existingCost))) (
                if (newCost < existingCost)
                    then newCost - existingCost
                    else 0.0


-- )

{- | getCharacterDelta determines the network add delta for each block (vector of characters)
if existing is lower then zero, else (existing - new)
 calculate d(u,v) + d(u',v') [existing display tree cost estimate] compared to
 d((union u,v), v') - d(u'.v')
need to use final assignemnts--so set prelim to final first
-}
getCharacterDelta
    ∷ (LG.Node, LG.Node, LG.Node, LG.Node, LG.Node, LG.Node) → DecoratedGraph → CharInfo → (VertexCost, VertexCost)
getCharacterDelta (_, v, _, v', a, b) inCharTree charInfo =
    -- getCharacterDelta (u,v,u',v',a,b) inCharTree charInfo =
    let doIA = False
        -- filterGaps = True
        -- uData = V.head $ V.head $ vertData $ fromJust $ LG.lab inCharTree u
        vData = V.head $ V.head $ vertData $ fromJust $ LG.lab inCharTree v
        vFinalData = V.head $ V.head $ PRE.setPreliminaryToFinalStates $ vertData $ fromJust $ LG.lab inCharTree v
        -- u'Data = V.head $ V.head $ vertData $ fromJust $ LG.lab inCharTree u'
        v'Data = V.head $ V.head $ vertData $ fromJust $ LG.lab inCharTree v'
        v'FinalData = V.head $ V.head $ PRE.setPreliminaryToFinalStates $ vertData $ fromJust $ LG.lab inCharTree v'
        aData = V.head $ V.head $ vertData $ fromJust $ LG.lab inCharTree a
        aFinalData = V.head $ V.head $ PRE.setPreliminaryToFinalStates $ vertData $ fromJust $ LG.lab inCharTree a
        bData = V.head $ V.head $ vertData $ fromJust $ LG.lab inCharTree b

        -- unionUV = M.union2Single doIA filterGaps uData vData charInfo
        -- (_,dUV) =  M.median2Single doIA uData vData charInfo
        -- dUV = vertexCost $ fromJust $ LG.lab inCharTree u
        -- dU'V' = vertexCost $ fromJust $ LG.lab inCharTree u'
        -- (_, dUnionUVV') = M.median2Single doIA unionUV v'Data charInfo

        (newX, dVV') = M.median2Single doIA vFinalData v'FinalData charInfo
        (_, dAX) = M.median2Single doIA aFinalData newX charInfo
        (_, dAV) = M.median2Single doIA aData vData charInfo
        (_, dV'B) = M.median2Single doIA v'Data bData charInfo
    in  -- trace ("GCD: " <> (show (dVV' + dAX, dAV + dV'B))) (
        (dVV' + dAX, dAV + dV'B)


-- if dUnionUVV' - dU'V' < dU'V' then dUnionUVV' - dU'V'
-- else 0.0
-- )

{- | heuristicAddDelta takes the existing graph, edge pair, and new nodes to create and makes
the new nodes and reoptimizes starting nodes of two edges.  Returns cost delta based on
previous and new node resolution caches
returns cost delta and the reoptimized nodes for use in incremental optimization
original edges (to be deleted) (u,v) and (u',v'), n1 inserted in (u,v) and n2 inserted into (u',v')
creates (n1, n2), (u,n1), (n1,v), (u',n2), (n2, v')
-}
heuristicAddDelta
    ∷ GlobalSettings
    → ReducedPhylogeneticGraph
    → (LG.LEdge b, LG.LEdge b)
    → LG.Node
    → LG.Node
    → (VertexCost, LG.LNode VertexInfo, LG.LNode VertexInfo, LG.LNode VertexInfo, LG.LNode VertexInfo)
heuristicAddDelta inGS inPhyloGraph ((u, v, _), (u', v', _)) n1 n2 =
    if LG.isEmpty (fst5 inPhyloGraph)
        then error "Empty graph in heuristicAddDelta"
        else
            if graphType inGS == HardWired
                then
                    let uvVertData = M.makeEdgeData False True (thd5 inPhyloGraph) (fft5 inPhyloGraph) (u, v, dummyEdge)
                        uvPrimeData = M.makeEdgeData False True (thd5 inPhyloGraph) (fft5 inPhyloGraph) (u', v', dummyEdge)
                        hardDelta = V.sum $ fmap V.sum $ fmap (fmap snd) $ POSW.createVertexDataOverBlocks uvVertData uvPrimeData (fft5 inPhyloGraph) []
                    in  (hardDelta, dummyNode, dummyNode, dummyNode, dummyNode)
                else -- softwired

                    let uLab = fromJust $ LG.lab (thd5 inPhyloGraph) u
                        uPrimeLab = fromJust $ LG.lab (thd5 inPhyloGraph) u'
                        vLab = fromJust $ LG.lab (thd5 inPhyloGraph) v
                        vPrimeLab = fromJust $ LG.lab (thd5 inPhyloGraph) v'
                        uPrimeOtherChild = head $ filter ((/= v') . fst) $ LG.labDescendants (thd5 inPhyloGraph) (u', uPrimeLab)
                        uOtherChild = head $ filter ((/= v) . fst) $ LG.labDescendants (thd5 inPhyloGraph) (u, uLab)

                        -- direction first edge to second so n2 is outdegree 1 to v'
                        n2Lab = NEW.getOutDegree1VertexSoftWired n2 vPrimeLab (thd5 inPhyloGraph) [n2]
                        uPrimeLabAfter = NEW.getOutDegree2VertexSoftWired inGS (fft5 inPhyloGraph) u' (n2, n2Lab) uPrimeOtherChild (thd5 inPhyloGraph)
                        n1Lab = NEW.getOutDegree2VertexSoftWired inGS (fft5 inPhyloGraph) n1 (v, vLab) (n2, n2Lab) (thd5 inPhyloGraph)
                        uLabAfter = NEW.getOutDegree2VertexSoftWired inGS (fft5 inPhyloGraph) u uOtherChild (n1, n1Lab) (thd5 inPhyloGraph)

                        -- cost of resolutions
                        (_, uCostBefore) = NEW.extractDisplayTrees (Just (-1)) False (vertexResolutionData uLab)
                        (_, uPrimeCostBefore) = NEW.extractDisplayTrees (Just (-1)) False (vertexResolutionData uPrimeLab)
                        (_, uCostAfter) = NEW.extractDisplayTrees (Just (-1)) False (vertexResolutionData uLabAfter)
                        (_, uPrimeCostAfter) = NEW.extractDisplayTrees (Just (-1)) False (vertexResolutionData uPrimeLabAfter)

                        addNetDelta = (uCostAfter - uCostBefore) + (uPrimeCostAfter - uPrimeCostBefore)
                    in  -- trace ("HAD: " <> (show (uCostAfter, uCostBefore, uPrimeCostAfter, uPrimeCostBefore)) <> " -> " <> (show addNetDelta)) $
                        if null (filter ((/= v') . fst) $ LG.labDescendants (thd5 inPhyloGraph) (u', uPrimeLab))
                            || null (filter ((/= v) . fst) $ LG.labDescendants (thd5 inPhyloGraph) (u, uLab))
                            then (infinity, dummyNode, dummyNode, dummyNode, dummyNode)
                            else -- this should not happen--should try to create new edges from children of net edges

                                if (length $ LG.descendants (thd5 inPhyloGraph) u) < 2 || (length $ LG.descendants (thd5 inPhyloGraph) u') < 2
                                    then error ("Outdegree 1 nodes in heuristicAddDelta")
                                    else (addNetDelta, (u, uLabAfter), (u', uPrimeLabAfter), (n1, n1Lab), (n2, n2Lab))


{- | deltaPenaltyAdjustment takes number of leaves and Phylogenetic graph and returns a heuristic graph penalty for adding a single network edge
if Wheeler2015Network, this is based on all changes affecting a single block (most permissive) and Wheeler 2015 calculation of penalty
if PMDLGraph -- KMDL not yet implemented
if NoNetworkPenalty then 0
modification "add" or subtrct to calculate delta
always delta is positive--whether neg or pos is deltermined when used
-}
deltaPenaltyAdjustment
    ∷ GlobalSettings
    → ReducedPhylogeneticGraph
    → String
    → VertexCost
deltaPenaltyAdjustment inGS inGraph modification =
    -- trace ("DPA: entering: " <> (show $ graphFactor inGS)) (
    let numLeaves = numDataLeaves inGS
        edgeCostModel = graphFactor inGS
        (_, _, _, networkNodeList) = LG.splitVertexList (fst5 inGraph)
    in  if edgeCostModel == NoNetworkPenalty
            then -- trace ("DPA: No penalty")
                0.0
            else -- else if length networkNodeList == 0 then
            -- trace ("DPA: No cost")
            --   0.0

                if edgeCostModel == Wheeler2015Network
                    then (snd5 inGraph) / (fromIntegral $ 2 * ((2 * numLeaves) - 2) + (2 * (length networkNodeList)))
                    else
                        if edgeCostModel == PMDLGraph
                            then -- trace  ("DPW: In PMDLGraph") (

                                if graphType inGS == Tree
                                    then fst $ IL.head (graphComplexityList inGS)
                                    else
                                        if graphType inGS == SoftWired
                                            then
                                                let currentComplexity = fst $ (graphComplexityList inGS) IL.!!! (length networkNodeList)
                                                    nextComplexity =
                                                        if modification == "add"
                                                            then fst $ (graphComplexityList inGS) IL.!!! ((length networkNodeList) + 1)
                                                            else
                                                                if modification == "delete"
                                                                    then fst $ (graphComplexityList inGS) IL.!!! ((length networkNodeList) - 1)
                                                                    else error ("SoftWired deltaPenaltyAdjustment modification not recognized: " <> modification)
                                                in  abs (currentComplexity - nextComplexity)
                                            else
                                                if graphType inGS == HardWired
                                                    then
                                                        let currentComplexity = snd $ (graphComplexityList inGS) IL.!!! (length networkNodeList)
                                                            nextComplexity =
                                                                if modification == "add"
                                                                    then snd $ (graphComplexityList inGS) IL.!!! ((length networkNodeList) + 1)
                                                                    else
                                                                        if modification == "delete"
                                                                            then snd $ (graphComplexityList inGS) IL.!!! ((length networkNodeList) - 1)
                                                                            else error ("HardWired deltaPenaltyAdjustment modification not recognized: " <> modification)
                                                        in  abs (currentComplexity - nextComplexity)
                                                    else error ("Graph type not yet implemented: " <> (show $ graphType inGS))
                            else -- )

                                if edgeCostModel == Wheeler2023Network
                                    then -- same as W15 for heuristic penalty for single edge
                                        (snd5 inGraph) / (fromIntegral $ 2 * ((2 * numLeaves) - 2) + (2 * (length networkNodeList)))
                                    else error ("Network edge cost model not yet implemented: " <> (show edgeCostModel))


-- )

{- | deleteEachNetEdge takes a phylogenetic graph and deletes all network edges one at time
and returns best list of new Phylogenetic Graphs and cost
even if worse--could be used for simulated annealing later
if equal returns unique graph list
-}
deleteEachNetEdge
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Int
    → Bool
    → Bool
    → Bool
    → Maybe SAParams
    → ReducedPhylogeneticGraph
    → PhyG ([ReducedPhylogeneticGraph], VertexCost, Maybe SAParams)
deleteEachNetEdge inGS inData rSeed numToKeep doSteepest doRandomOrder force inSimAnnealParams inPhyloGraph =
    -- trace ("DENE start") (
    if LG.isEmpty $ thd5 inPhyloGraph
        then do
            pure ([], infinity, inSimAnnealParams) -- error "Empty input phylogenetic graph in deleteAllNetEdges"
        else
            let currentCost = snd5 inPhyloGraph

                -- potentially randomize order of list
                networkEdgeList' = LG.netEdges $ thd5 inPhyloGraph
                networkEdgeList =
                    if not doRandomOrder
                        then networkEdgeList'
                        else permuteList rSeed networkEdgeList'

                --- parallel
                action ∷ LG.Edge → PhyG ReducedPhylogeneticGraph
                action = deleteNetEdge inGS inData inPhyloGraph force
            in  do
                    delPar ← getParallelChunkTraverse
                    delNetEdgeList ← delPar action networkEdgeList
                    -- mapM (deleteNetEdge inGS inData inPhyloGraph force) networkEdgeList
                    deleteNetEdgeRecursiveList ← deleteNetEdgeRecursive inGS inData inPhyloGraph force inSimAnnealParams networkEdgeList
                    let (newGraphList, newSAParams) =
                            if not doSteepest
                                then -- TODO
                                -- (PU.seqParMap (parStrategy $ lazyParStrat inGS) (deleteNetEdge inGS inData inPhyloGraph force) networkEdgeList, U.incrementSimAnnealParams inSimAnnealParams)
                                    (delNetEdgeList, U.incrementSimAnnealParams inSimAnnealParams)
                                else deleteNetEdgeRecursiveList

                    let bestCostGraphList = filter ((/= infinity) . snd5) $ GO.selectGraphs Best numToKeep 0.0 (-1) newGraphList
                    let minCost =
                            if null bestCostGraphList
                                then infinity
                                else minimum $ fmap snd5 bestCostGraphList

                    -- no network edges to delete
                    if null networkEdgeList
                        then do
                            logWith LogInfo ("\tNo network edges to delete" <> "\n")
                            pure ([inPhyloGraph], currentCost, inSimAnnealParams)
                        else -- single if steepest so no neeed to unique--and have run through all options (including SA stuff) via recursive call

                            if doSteepest
                                then do
                                    pure (newGraphList, minCost, newSAParams)
                                else -- "all" option needs to recurse since does all available edges at each step
                                -- logic is here since not in the deleteNetEdge function

                                    if isNothing inSimAnnealParams
                                        then
                                            if minCost < currentCost
                                                then -- trace ("DENE--Delete net edge return:" <> (show (minCost,length uniqueCostGraphList))) (

                                                    let newRandIntList = take (length bestCostGraphList) (randomIntList rSeed)
                                                        annealParamList = U.generateUniqueRandList (length bestCostGraphList) newSAParams

                                                        -- parallel
                                                        deleteAction ∷ (Maybe SAParams, Int, ReducedPhylogeneticGraph) → PhyG ([ReducedPhylogeneticGraph], VertexCost, Maybe SAParams)
                                                        deleteAction = deleteEachNetEdge' inGS inData numToKeep doSteepest doRandomOrder force
                                                    in  do
                                                            -- TODO
                                                            -- nextGraphTripleList = PU.seqParMap (parStrategy $ lazyParStrat inGS) (deleteEachNetEdge' inGS inData numToKeep doSteepest doRandomOrder force) (zip3 annealParamList newRandIntList bestCostGraphList)
                                                            deletePar ← getParallelChunkTraverse
                                                            nextGraphTripleList ← deletePar deleteAction (zip3 annealParamList newRandIntList bestCostGraphList)
                                                            -- mapM (deleteEachNetEdge' inGS inData numToKeep doSteepest doRandomOrder force) (zip3 annealParamList newRandIntList bestCostGraphList)

                                                            let newMinCost = minimum $ fmap snd3 nextGraphTripleList
                                                            let newGraphListBetter = filter ((== newMinCost) . snd5) $ concatMap fst3 nextGraphTripleList

                                                            pure (GO.selectGraphs Unique numToKeep 0.0 (-1) $ newGraphListBetter, newMinCost, newSAParams)
                                                else do
                                                    pure (bestCostGraphList, currentCost, newSAParams)
                                        else -- SA anneal/Drift

                                        -- always take better

                                            if minCost < currentCost
                                                then do
                                                    pure (bestCostGraphList, minCost, newSAParams)
                                                else -- check if hit step limit--more for SA than drift

                                                    if ((currentStep $ fromJust inSimAnnealParams) >= (numberSteps $ fromJust inSimAnnealParams))
                                                        || ((driftChanges $ fromJust inSimAnnealParams) >= (driftMaxChanges $ fromJust inSimAnnealParams))
                                                        then do
                                                            pure ([inPhyloGraph], snd5 inPhyloGraph, inSimAnnealParams)
                                                        else -- otherwise do the anneal/Drift accept, or keep going on input graph

                                                            let (acceptGraph, nextSAParams) = U.simAnnealAccept inSimAnnealParams currentCost minCost
                                                            in  if acceptGraph
                                                                    then do
                                                                        pure (bestCostGraphList, minCost, newSAParams)
                                                                    else do
                                                                        deleteEachNetEdge inGS inData (head $ randomIntList rSeed) numToKeep doSteepest doRandomOrder force nextSAParams inPhyloGraph


{- | deleteEachNetEdge' is a wrapper around deleteEachNetEdge to allow for zipping new random seeds for each
replicate
-}
deleteEachNetEdge'
    ∷ GlobalSettings
    → ProcessedData
    → Int
    → Bool
    → Bool
    → Bool
    → (Maybe SAParams, Int, ReducedPhylogeneticGraph)
    → PhyG ([ReducedPhylogeneticGraph], VertexCost, Maybe SAParams)
deleteEachNetEdge' inGS inData numToKeep doSteepest doRandomOrder force (inSimAnnealParams, rSeed, inPhyloGraph) =
    deleteEachNetEdge inGS inData rSeed numToKeep doSteepest doRandomOrder force inSimAnnealParams inPhyloGraph


{- | deleteNetEdgeRecursive like deleteEdge, deletes an edge (checking if network) and rediagnoses graph
contacts in=out=1 edges and removes node, reindexing nodes and edges
except returns on first better (as opposed to do all deletes first)
or sim annleal/drift
-}
deleteNetEdgeRecursive
    ∷ GlobalSettings
    → ProcessedData
    → ReducedPhylogeneticGraph
    → Bool
    → Maybe SAParams
    → [LG.Edge]
    → PhyG ([ReducedPhylogeneticGraph], Maybe SAParams)
deleteNetEdgeRecursive inGS inData inPhyloGraph force inSimAnnealParams inEdgeToDeleteList =
    if null inEdgeToDeleteList
        then do
            pure ([], inSimAnnealParams)
        else
            let {- Unclear if should adjust to number of rounds if already limiting to graphsSteepest value
                 saRounds = if isNothing inSimAnnealParams then 1
                           else rounds $ fromJust inSimAnnealParams

                 (numGraphsToExamine, _) = divMod PU.getNumThreads saRounds -- this may not "drift" if finds alot better, but that's how its supposed to work
                -}
                numGraphsToExamine = graphsSteepest inGS -- min (graphsSteepest inGS) PU.getNumThreads
                -- edgeToDelete = head inEdgeToDeleteList
                edgeToDeleteList = take numGraphsToExamine inEdgeToDeleteList

                leafGraph = LG.extractLeafGraph $ thd5 inPhyloGraph

                -- prune other edges if now unused
                pruneEdges = False

                -- don't warn that edges are being pruned
                warnPruneEdges = False

                -- graph optimization from root
                startVertex = Nothing

                -- parallel
                deleteAction ∷ LG.Edge → PhyG (SimpleGraph, Bool)
                deleteAction = deleteNetworkEdge (fst5 inPhyloGraph)

                softTraverse ∷ SimpleGraph → PhyG ReducedPhylogeneticGraph
                softTraverse = T.multiTraverseFullyLabelSoftWiredReduced inGS inData pruneEdges warnPruneEdges leafGraph startVertex

                hardTraverse ∷ SimpleGraph → PhyG ReducedPhylogeneticGraph
                hardTraverse = T.multiTraverseFullyLabelHardWiredReduced inGS inData leafGraph startVertex
            in  do
                    -- calls general funtion to remove network graph edge
                    -- (delSimple, wasModified) = deleteNetworkEdge (fst5 inPhyloGraph) edgeToDelete
                    -- TODO
                    deletePar ← getParallelChunkTraverse
                    simpleGraphList' ← deletePar deleteAction edgeToDeleteList
                    -- mapM (deleteNetworkEdge (fst5 inPhyloGraph)) edgeToDeleteList
                    let simpleGraphList = fmap fst $ filter ((== True) . snd) simpleGraphList'
                    -- \$ PU.seqParMap (parStrategy $ lazyParStrat inGS) (deleteNetworkEdge (fst5 inPhyloGraph)) edgeToDeleteList

                    -- delSimple = GO.contractIn1Out1EdgesRename $ LG.delEdge edgeToDelete $ fst5 inPhyloGraph

                    -- (heuristicDelta, _, _) = heuristicDeleteDelta inGS inPhyloGraph edgeToDelete
                    -- heuristicDelta = 0.0

                    -- can treat as negative for delete
                    -- edgeAddDelta = deltaPenaltyAdjustment inGS inPhyloGraph "delete"

                    newPhyloGraphList' ←
                        if (graphType inGS == SoftWired)
                            then do
                                softPar ← getParallelChunkTraverse
                                softResult ← softPar softTraverse simpleGraphList
                                pure softResult
                            else -- PU.seqParMap (parStrategy $ lazyParStrat inGS) (T.multiTraverseFullyLabelSoftWiredReduced inGS inData pruneEdges warnPruneEdges leafGraph startVertex) simpleGraphList

                                if (graphType inGS == HardWired)
                                    then do
                                        hardPar ← getParallelChunkTraverse
                                        hardResult ← hardPar hardTraverse simpleGraphList
                                        pure hardResult
                                    else -- PU.seqParMap (parStrategy $ lazyParStrat inGS) (T.multiTraverseFullyLabelHardWiredReduced inGS inData leafGraph startVertex) simpleGraphList
                                        error "Unsupported graph type in deleteNetEdge.  Must be soft or hard wired"

                    let newPhyloGraphList = GO.selectGraphs Best (maxBound ∷ Int) 0.0 (-1) newPhyloGraphList'

                    -- if not modified return original graph
                    -- This check seems to be issue with delete not functioning properly
                    if null simpleGraphList
                        then do
                            pure ([inPhyloGraph], inSimAnnealParams)
                        else -- forcing delete for move

                            if force
                                then do
                                    -- trace ("DNERec forced")
                                    pure (newPhyloGraphList, inSimAnnealParams)
                                else -- regular search not sim anneal/drift

                                    if (isNothing inSimAnnealParams)
                                        then -- return if better

                                            if (snd5 $ head newPhyloGraphList) < (snd5 inPhyloGraph)
                                                then do
                                                    -- trace  ("DNERec Better -> " <> (show $ snd5 newPhyloGraph))
                                                    pure (newPhyloGraphList, inSimAnnealParams)
                                                else do
                                                    -- need to update edge list for new graph
                                                    -- potentially randomize order of list
                                                    deleteNetEdgeRecursive inGS inData inPhyloGraph force inSimAnnealParams (drop numGraphsToExamine inEdgeToDeleteList)
                                        else -- sim anneal/drift

                                        -- if better always accept

                                            if (snd5 $ head newPhyloGraphList) < (snd5 inPhyloGraph)
                                                then -- these graph costs are "exact" or at least non-heuristic--needs to be updated when get a good heuristic

                                                    let (_, nextSAParams) = U.simAnnealAccept inSimAnnealParams (snd5 inPhyloGraph) (snd5 $ head newPhyloGraphList)
                                                    in  do
                                                            pure (newPhyloGraphList, nextSAParams)
                                                else -- check if hit step limit--more for SA than drift

                                                    if ((currentStep $ fromJust inSimAnnealParams) >= (numberSteps $ fromJust inSimAnnealParams))
                                                        || ((driftChanges $ fromJust inSimAnnealParams) >= (driftMaxChanges $ fromJust inSimAnnealParams))
                                                        then do
                                                            pure ([inPhyloGraph], inSimAnnealParams)
                                                        else -- otherwise do the anneal/Drift accept

                                                            let (acceptGraph, nextSAParams) = U.simAnnealAccept inSimAnnealParams (snd5 inPhyloGraph) (snd5 $ head newPhyloGraphList)
                                                            in  if acceptGraph
                                                                    then do
                                                                        pure (newPhyloGraphList, nextSAParams)
                                                                    else do
                                                                        deleteNetEdgeRecursive inGS inData inPhyloGraph force nextSAParams (drop numGraphsToExamine inEdgeToDeleteList)


{- | deleteEdge deletes an edge (checking if network) and rediagnoses graph
contacts in=out=1 edgfes and removes node, reindexing nodes and edges
naive for now
force requires reoptimization no matter what--used for net move
skipping heuristics for now--awful
calls deleteNetworkEdge that has various graph checks
-}
deleteNetEdge
    ∷ GlobalSettings
    → ProcessedData
    → ReducedPhylogeneticGraph
    → Bool
    → LG.Edge
    → PhyG ReducedPhylogeneticGraph
deleteNetEdge inGS inData inPhyloGraph force edgeToDelete =
    if LG.isEmpty $ thd5 inPhyloGraph
        then error "Empty input phylogenetic graph in deleteNetEdge"
        else
            if not (LG.isNetworkEdge (fst5 inPhyloGraph) edgeToDelete)
                then error ("Edge to delete: " <> (show edgeToDelete) <> " not in graph:\n" <> (LG.prettify $ fst5 inPhyloGraph))
                else do
                    -- trace ("DNE: " <> (show edgeToDelete)) (
                    (delSimple, wasModified) ← deleteNetworkEdge (fst5 inPhyloGraph) edgeToDelete

                    -- delSimple = GO.contractIn1Out1EdgesRename $ LG.delEdge edgeToDelete $ fst5 inPhyloGraph

                    -- prune other edges if now unused
                    let pruneEdges = False

                    -- don't warn that edges are being pruned
                    let warnPruneEdges = False

                    -- graph optimization from root
                    let startVertex = Nothing

                    -- (heuristicDelta, _, _) = heuristicDeleteDelta inGS inPhyloGraph edgeToDelete

                    -- edgeAddDelta = deltaPenaltyAdjustment inGS inPhyloGraph "delete"

                    -- full two-pass optimization--cycles checked in edge deletion function
                    let leafGraph = LG.extractLeafGraph $ thd5 inPhyloGraph

                    newPhyloGraph ←
                        if (graphType inGS == SoftWired)
                            then T.multiTraverseFullyLabelSoftWiredReduced inGS inData pruneEdges warnPruneEdges leafGraph startVertex delSimple
                            else
                                if (graphType inGS == HardWired)
                                    then T.multiTraverseFullyLabelHardWiredReduced inGS inData leafGraph startVertex delSimple
                                    else error "Unsupported graph type in deleteNetEdge.  Must be soft or hard wired"
                    -- check if deletino modified graph
                    if not wasModified
                        then do
                            pure inPhyloGraph
                        else -- else if force || (graphType inGS) == HardWired then

                            if force
                                then do
                                    -- trace ("DNE forced")
                                    pure newPhyloGraph
                                else -- if (heuristicDelta / (dynamicEpsilon inGS)) - edgeAddDelta < 0 then newPhyloGraph

                                    if (snd5 newPhyloGraph) < (snd5 inPhyloGraph)
                                        then do
                                            -- trace ("DNE Better: " <> (show $ snd5 newPhyloGraph))
                                            pure newPhyloGraph
                                        else do
                                            -- trace ("DNE Not Better: " <> (show $ snd5 newPhyloGraph))
                                            pure inPhyloGraph


-- )

{- | deleteNetworkEdge deletes a network edges from a simple graph
retuns newGraph if can be modified or input graph with Boolean to tell if modified
and contracts, reindexes/names internaledges/veritices around deletion
can't raise to general graph level due to vertex info
in edges (b,a) (c,a) (a,d), deleting (a,b) deletes node a, inserts edge (b,d)
contacts node c since  now in1out1 vertex
checks for chained network edges--can be created by progressive deletion
checks for cycles now
shouldn't need for check for creating a node with children that are both network nodes
since that would require that condition coming in and shodl be there--ie checked earlier in addition and input
-}
deleteNetworkEdge ∷ SimpleGraph → LG.Edge → PhyG (SimpleGraph, Bool)
deleteNetworkEdge inGraph inEdge@(p1, nodeToDelete) =
    if LG.isEmpty inGraph
        then error ("Cannot delete edge from empty graph")
        else
            let childrenNodeToDelete = LG.descendants inGraph nodeToDelete
                parentsNodeToDelete = LG.parents inGraph nodeToDelete
                -- parentNodeToKeep = head $ filter (/= p1) parentsNodeToDelete
                -- newEdge = (parentNodeToKeep, head childrenNodeToDelete, 0.0)
                -- newGraph = LG.insEdge newEdge $ LG.delNode nodeToDelete inGraph
                newGraph = LG.delEdge inEdge inGraph
                -- newGraph' = GO.contractIn1Out1EdgesRename newGraph

                -- conversion as if input--see if affects length
                -- newGraph'' = GO.convertGeneralGraphToPhylogeneticGraph False newGraph
                newGraph'' = GO.contractIn1Out1EdgesRename newGraph
            in  -- error conditions and creation of chained network edges (forbidden in phylogenetic graph--causes resolutoin cache issues)
                if length childrenNodeToDelete /= 1
                    then error ("Cannot delete non-network edge in deleteNetworkEdge: (1)" <> (show inEdge) <> "\n" <> (LG.prettyIndices inGraph))
                    else
                        if length parentsNodeToDelete /= 2
                            then error ("Cannot delete non-network edge in deleteNetworkEdge (2): " <> (show inEdge) <> "\n" <> (LG.prettyIndices inGraph))
                            else -- warning if chained on input, skip if chained net edges in output

                                if (LG.isNetworkNode inGraph p1)
                                    then do
                                        -- error ("Error: Chained network nodes in deleteNetworkEdge : " <> (show inEdge) <> "\n" <> (LG.prettyIndices inGraph) <> " skipping")
                                        logWith LogWarn ("\tWarning: Chained network nodes in deleteNetworkEdge skipping deletion" <> "\n")
                                        pure (LG.empty, False)
                                    else
                                        if LG.hasChainedNetworkNodes newGraph''
                                            then do
                                                logWith LogWarn ("\tWarning: Chained network nodes in deleteNetworkEdge skipping deletion (2)" <> "\n")
                                                pure (LG.empty, False)
                                            else
                                                if LG.isEmpty newGraph''
                                                    then do
                                                        pure (LG.empty, False)
                                                    else do
                                                        {-trace ("DNE: Edge to delete " <> (show inEdge) <> " cnd " <> (show childrenNodeToDelete) <> " pnd " <> (show parentsNodeToDelete) <> " pntk " <> (show parentNodeToKeep)
                                                           <> " ne " <> (show newEdge) <> "\nInGraph: " <> (LG.prettyIndices inGraph) <> "\nNewGraph: " <> (LG.prettyIndices newGraph) <> "\nNewNewGraph: "
                                                           <> (LG.prettyIndices newGraph')) -}
                                                        pure (newGraph'', True)


{- | heuristicDeleteDelta takes the existing graph, edge to delete,
reoptimizes starting nodes of two created edges.  Returns cost delta based on
previous and new node resolution caches
delete n1 -> n2, create u -> v, u' -> v'
assumes original is edge n1 -> n2, u' -> (n2, X), n1 -> (n2,v), u (n1,Y)
-}
heuristicDeleteDelta
    ∷ GlobalSettings
    → ReducedPhylogeneticGraph
    → LG.Edge
    → (VertexCost, LG.LNode VertexInfo, LG.LNode VertexInfo)
heuristicDeleteDelta inGS inPhyloGraph (n1, n2) =
    if LG.isEmpty (fst5 inPhyloGraph)
        then error "Empty graph in heuristicDeleteDelta"
        else
            if graphType inGS == HardWired
                then -- ensures delete--will always be lower or equakl cost if delete edge from HardWired
                    (-1, dummyNode, dummyNode)
                else
                    let inGraph = thd5 inPhyloGraph
                        u = head $ LG.parents inGraph n1
                        u' = head $ filter (/= n1) $ LG.parents inGraph n2
                        v' = head $ LG.descendants inGraph n2
                        v = head $ filter (/= n2) $ LG.descendants inGraph n1

                        uLab = fromJust $ LG.lab inGraph u
                        uPrimeLab = fromJust $ LG.lab inGraph u'
                        vLab = fromJust $ LG.lab inGraph v
                        vPrimeLab = fromJust $ LG.lab inGraph v'

                        uOtherChild = head $ filter ((/= n1) . fst) $ LG.labDescendants inGraph (u, uLab)
                        uPrimeOtherChild = head $ filter ((/= n2) . fst) $ LG.labDescendants inGraph (u', uPrimeLab)

                        -- skip over netnodes
                        uLabAfter = NEW.getOutDegree2VertexSoftWired inGS (fft5 inPhyloGraph) u (v, vLab) uOtherChild inGraph
                        uPrimeLabAfter = NEW.getOutDegree2VertexSoftWired inGS (fft5 inPhyloGraph) u' (v', vPrimeLab) uPrimeOtherChild inGraph

                        -- cost of resolutions
                        (_, uCostBefore) = NEW.extractDisplayTrees (Just (-1)) False (vertexResolutionData uLab)
                        (_, uPrimeCostBefore) = NEW.extractDisplayTrees (Just (-1)) False (vertexResolutionData uPrimeLab)
                        (_, uCostAfter) = NEW.extractDisplayTrees (Just (-1)) False (vertexResolutionData uLabAfter)
                        (_, uPrimeCostAfter) = NEW.extractDisplayTrees (Just (-1)) False (vertexResolutionData uPrimeLabAfter)

                        addNetDelta = uCostAfter - uCostBefore + uPrimeCostAfter - uPrimeCostBefore
                    in  -- this should not happen--should try to crete new edges from children of net edges
                        if null (LG.parents inGraph n1)
                            || null (filter (/= n1) $ LG.parents inGraph n2)
                            || null (LG.descendants inGraph n2)
                            || null (filter (/= n2) $ LG.descendants inGraph n1)
                            || null (filter ((/= n2) . fst) $ LG.labDescendants inGraph (u', uPrimeLab))
                            || null (filter ((/= n1) . fst) $ LG.labDescendants inGraph (u, uLab))
                            then (infinity, dummyNode, dummyNode)
                            else -- this should not happen--should try to crete new edges from children of net edges

                                if (length (LG.parents inGraph n1) /= 1)
                                    || (length (LG.parents inGraph n2) /= 2)
                                    || (length (LG.descendants inGraph n2) /= 1)
                                    || (length (LG.descendants inGraph n1) /= 2)
                                    then error ("Graph malformation in numbers of parents and children in heuristicDeleteDelta")
                                    else (addNetDelta, (u, uLabAfter), (u', uPrimeLabAfter))

{-
-- | insertNetEdgeBothDirections calls insertNetEdge for both u -> v and v -> u new edge orientations
insertNetEdgeBothDirections :: GlobalSettings -> ProcessedData -> ReducedPhylogeneticGraph ->  Maybe VertexCost -> (LG.LEdge b, LG.LEdge b) -> [ReducedPhylogeneticGraph]
insertNetEdgeBothDirections inGS inData inPhyloGraph preDeleteCost (u,v) = fmap (insertNetEdge inGS inData inPhyloGraph preDeleteCost) [(u,v), (v,u)]
-}
