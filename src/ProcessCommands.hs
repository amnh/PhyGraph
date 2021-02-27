{- |
Module      :  ProcessCommands.hs
Description :  Progam to perform phylogenetic searchs on general graphs with diverse data types
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

module ProcessCommands where

import           Control.Exception
import           Data.Typeable
import           Control.Monad.Catch
import           Data.Char
--import           Debug.Trace

import           Types


-- | Exception machinery for bad intial command line
data BadCommandLine = BadCommandLine
    deriving Typeable
instance Show BadCommandLine where
    show BadCommandLine = "Error: Program requires a single argument--the name of command script file.\n"
instance Exception BadCommandLine

-- | Exception machinery for empty command file
data EmptyCommandFile = EmptyCommandFile
    deriving Typeable
instance Show EmptyCommandFile where
    show EmptyCommandFile = "Error: Empty command script file.\n"
instance Exception EmptyCommandFile




-- | commandList takes a String from a file and returns a list of commands and their arguments
-- these are syntactically verified, but any input files are not checked
commandList :: String -> [Command]
commandList rawContents =
	if null rawContents then throwM EmptyCommandFile
	else [(Read,[])]