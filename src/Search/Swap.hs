{- |
Module      :  Swap.hs
Description :  Module specifying graph swapping rearrangement functions
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

module Search.Swap  ( swapMaster
                    ) where

import Types.Types
import qualified ParallelUtilities       as PU
import GeneralUtilities
import qualified Graphs.GraphOperations  as GO
import qualified Utilities.LocalGraph    as LG
import Utilities.Utilities               as U
import Debug.Trace
import           Data.Char
import           Text.Read
import           Data.Maybe
import qualified GraphOptimization.Traversals as T
import qualified Data.Vector as V
import qualified GraphOptimization.PreOrderFunctions as PRE
import qualified Data.List as L

-- | buildArgList is the list of valid build arguments
swapArgList :: [String]
swapArgList = ["spr","tbr", "keep", "steepest", "all"]


-- | swapMaster processes and spawns the swap functions
swapMaster ::  [Argument] -> GlobalSettings -> ProcessedData -> Int -> [PhylogeneticGraph] -> [PhylogeneticGraph]
swapMaster inArgs inGS inData rSeed inGraphList =
   trace ("Swapping " ++ (show $ length inGraphList) ++ " graphs") (
   if null inGraphList then []
   else 
      let fstArgList = fmap (fmap toLower . fst) inArgs
          sndArgList = fmap (fmap toLower . snd) inArgs
          lcArgList = zip fstArgList sndArgList
          checkCommandList = U.checkCommandArgs "swap" fstArgList swapArgList
   in
   -- check for valid command options
   if not checkCommandList then errorWithoutStackTrace ("Unrecognized command in 'swap': " ++ show inArgs)
   else 
       let keepList = filter ((=="keep").fst) lcArgList
           keepNum
            | length keepList > 1 =
              errorWithoutStackTrace ("Multiple 'keep' number specifications in swap command--can have only one: " ++ show inArgs)
            | null keepList = Just 1
            | otherwise = readMaybe (snd $ head keepList) :: Maybe Int
      in
      if isNothing keepNum then errorWithoutStackTrace ("Keep specification not an integer: "  ++ show (snd $ head keepList))
      else 
         let -- getting values to be passed for graph diagnosis later
             numLeaves = V.length $ fst3 inData
             leafGraph = T.makeSimpleLeafGraph inData
             leafDecGraph = T.makeLeafGraph inData
             leafGraphSoftWired = T.makeLeafGraphSoftWired inData
             hasNonExactChars = U.getNumberNonExactCharacters (thd3 inData) > 0
             charInfoVV = V.map thd3 $ thd3 inData

             -- process args for swap
             doSPR' = any ((=="spr").fst) lcArgList
             doTBR = any ((=="tbr").fst) lcArgList
             doSteepest' = any ((=="steepest").fst) lcArgList
             doAll = any ((=="all").fst) lcArgList
             doSPR = if (not doSPR' && not doTBR) then True
                     else doSPR'
             doSteepest = if (not doSteepest' && not doAll) then True
                          else doSteepest'
             (newGraphList, counterSPR)  = if doSPR then 
                                             let (graphListList, counterList) = unzip $ fmap (swapSPRTBR "spr" inGS inData (fromJust keepNum) doSteepest 0 numLeaves leafGraph leafDecGraph leafGraphSoftWired hasNonExactChars charInfoVV) inGraphList
                                             in (concat graphListList, sum counterList)
                                           else (inGraphList, 0)

             (newGraphList', counterTBR) = if doTBR then 
                                             let (graphListList, counterList) = unzip $ fmap (swapSPRTBR "tbr" inGS inData (fromJust keepNum) doSteepest 0 numLeaves leafGraph leafDecGraph leafGraphSoftWired hasNonExactChars charInfoVV) newGraphList
                                             in (concat graphListList, sum counterList)
                                           else (newGraphList, 0)
            in
            trace ("Swap rounds: " ++ (show counterSPR) ++ " SPR and " ++ (show counterTBR) ++ " TBR")
            newGraphList'
   )


-- | swapSPRTBR perfomrs SPR or TBR branch (edge) swapping on graphs
-- runs both SPR and TBR depending on argument since so much duplicated functionality
-- 'steepest' abandons swap graph and switces to found graph as soon as anyhting 'better'
-- is found. The alternative (all) examines the entire neighborhood and retuns the best result
-- the retuns is a list of better graphs and the number of swapping rounds were required to ge there
swapSPRTBR :: String -> GlobalSettings -> ProcessedData -> Int -> Bool -> Int -> Int -> SimpleGraph -> DecoratedGraph -> DecoratedGraph -> Bool-> V.Vector (V.Vector CharInfo) -> PhylogeneticGraph -> ([PhylogeneticGraph], Int)
swapSPRTBR swapType inGS inData numToKeep steepest counter numLeaves leafGraph leafDecGraph leafGraphSoftWired hasNonExactChars charInfoVV inGraph = 
   if LG.isEmpty (fst6 inGraph) then ([], 0)
   else 
      -- steepest takes immediate best
      if steepest then 
         let (betterGraphs, counter) = swapSteepest swapType inGS inData numToKeep steepest counter (snd6 inGraph) [] [inGraph] numLeaves leafGraph leafDecGraph leafGraphSoftWired hasNonExactChars charInfoVV
         in 
         if null betterGraphs then ([inGraph], 0)
         else (betterGraphs, counter)

      -- All does all swaps before taking best
      else  
         let (betterGraphs, counter) = swapAll swapType inGS inData numToKeep steepest counter (snd6 inGraph) [] [inGraph] numLeaves leafGraph leafDecGraph leafGraphSoftWired hasNonExactChars charInfoVV
         in 
         if null betterGraphs then ([inGraph], 0)
         else (betterGraphs, counter)
      
-- | swapAll performs branch swapping on all 'break' edges and all readditions
-- edges are unsorted since doing all of them
swapAll :: String -> GlobalSettings -> ProcessedData -> Int -> Bool -> Int -> VertexCost -> [PhylogeneticGraph] -> [PhylogeneticGraph] -> Int -> SimpleGraph -> DecoratedGraph -> DecoratedGraph -> Bool-> V.Vector (V.Vector CharInfo) -> ([PhylogeneticGraph], Int)
swapAll swapType inGS inData numToKeep steepest counter curBestCost curSameBetterList inGraphList numLeaves leafGraph leafDecGraph leafGraphSoftWired hasNonExactChars charInfoVV =
   if null inGraphList then (curSameBetterList, counter)
   else 
      let firstGraph = head inGraphList
          firstDecoratedGraph = thd6 firstGraph
          (firstRootIndex, _) = head $ LG.getRoots firstDecoratedGraph

          -- filter out edges from root since no use--would just rejoin
          firstEdgeList = filter ((/= firstRootIndex) . fst3) $ LG.labEdges firstDecoratedGraph

          -- determine edges to break on--'bridge' edges only
          breakEdgeList = if (graphType inGS) == Tree then firstEdgeList
                          else GO.getEdgeSplitList firstDecoratedGraph

          -- create list of breaks
          splitGraphList = fmap (GO.splitGraphOnEdge firstDecoratedGraph) breakEdgeList

          -- create rejoins-- adds in break list so don't remake the initial graph
          -- didn't concatMap so can parallelize later
          -- this cost prob doesn't include the root/net penalty--so need to figure out
          betterGraphList = concat $ fmap (rejoinGraphKeepBest curBestCost numToKeep steepest) splitGraphList 
          newBestCost = minimum $ fmap snd betterGraphList
          bestGraphList = fmap fst $ filter ((== newBestCost) . snd) betterGraphList


          bestSimpleGraphList = fmap GO.convertDecoratedToSimpleGraph bestGraphList
          newPhyloGraphList = if (graphType inGS == Tree) then
                                 let postTreeList = fmap (T.postDecorateTree' leafDecGraph charInfoVV numLeaves) bestSimpleGraphList
                                     preTreeList = fmap (PRE.preOrderTreeTraversal (finalAssignment inGS) hasNonExactChars) postTreeList
                                     bestPhyloTreeList = GO.selectPhylogeneticGraph [("best", (show newBestCost))] 0 ["best"] preTreeList
                                 in
                                 bestPhyloTreeList
                              else if (graphType inGS == SoftWired) then
                                 let postGraphList = fmap (T.postDecorateSoftWired' inGS leafGraphSoftWired charInfoVV numLeaves) bestSimpleGraphList
                                     updatedPostGraphList = fmap T.updateAndFinalizePostOrderSoftWired postGraphList

                                     localRootCost = if (rootCost inGS) == NoRootCost then 0.0
                                                     else if (rootCost inGS) == Wheeler2015Root then T.getW15RootCost inData $ head postGraphList
                                                     else error ("Root cost type " ++ (show $ rootCost inGS) ++ " is not yet implemented")

                                     -- for now do full two-pass decoration
                                     penaltyFactorList  = if (graphFactor inGS) == NoNetworkPenalty then replicate (length updatedPostGraphList) 0.0
                                                          else if (graphFactor inGS) == Wheeler2015Network then fmap T.getW15NetPenalty updatedPostGraphList
                                                          else error ("Network penalty type " ++ (show $ graphFactor inGS) ++ " is not yet implemented")
                                     newCostList = zipWith3 U.add3 penaltyFactorList (replicate (length updatedPostGraphList) localRootCost) (fmap snd6 updatedPostGraphList)

                                     updatedPostGraphList' = L.sortOn snd6 $ zipWith T.updatePhylogeneticGraphCost updatedPostGraphList newCostList

                                     preGraphList = fmap (PRE.preOrderTreeTraversal (finalAssignment inGS) hasNonExactChars) updatedPostGraphList'
                                     bestPhyloGraphList = GO.selectPhylogeneticGraph [("best", (show $ snd6 $ head updatedPostGraphList'))] 0 ["best"] preGraphList
                                 in
                                 bestPhyloGraphList
                              else error ("Graph tyhpe not implemented: " ++ (show $ graphType inGS))


      in
      trace ("Breakable Edges :" ++ (show $ fmap LG.toEdge breakEdgeList)) (
      
      -- either no better or more of same cost graphs
      if newBestCost == curBestCost then swapAll swapType inGS inData numToKeep steepest (counter + 1) newBestCost [firstGraph] ((tail inGraphList) ++ newPhyloGraphList) numLeaves leafGraph leafDecGraph leafGraphSoftWired hasNonExactChars charInfoVV

      -- better cost graphs
      else swapAll swapType inGS inData numToKeep steepest (counter + 1) newBestCost [] newPhyloGraphList numLeaves leafGraph leafDecGraph leafGraphSoftWired hasNonExactChars charInfoVV
      )


-- | rejoinGraphKeepBest rejoins split trees on available edges (non-root, and not original split)
-- if steepest is False does not sort order of edges, other wise sorts in order of closness to original edge
rejoinGraphKeepBest :: VertexCost -> Int -> Bool -> (LG.Gr a b, LG.Node, LG.Node, LG.Node) -> [(LG.Gr a b, VertexCost)]
rejoinGraphKeepBest curBestCost numToKeep steepest (splitGraph, graphRoot, prunedGraphRootIndex, originalConnectionOfPruned) = 
   []


-- | swapSteepest performs branch swapping greedily swithcing to found graph if better
swapSteepest :: String -> GlobalSettings -> ProcessedData -> Int -> Bool -> Int -> VertexCost -> [PhylogeneticGraph] -> [PhylogeneticGraph] -> Int -> SimpleGraph -> DecoratedGraph -> DecoratedGraph -> Bool-> V.Vector (V.Vector CharInfo) -> ([PhylogeneticGraph], Int)
swapSteepest swapType inGS inData numToKeep steepest counter curBestCost curBetterList inGraphList  numLeaves leafGraph leafDecGraph leafGraphSoftWired hasNonExactChars charInfoVV =
   if null inGraphList then (curBetterList, counter)
   else 
      (inGraphList, counter)
