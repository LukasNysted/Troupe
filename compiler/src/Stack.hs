{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}


module Stack 
where


import qualified Basics
import           RetCPS (VarName (..))
import           IR ( Identifier(..)
                    , VarAccess(..), HFN (..), Fields (..), Ident
                    , ppId,ppFunCall,ppArgs
                    )
import qualified IR (textOfBinOp,textOfUnOp,FunDef (..))
import Raw (RawExpr (..), ComplexExpr (..), RawType(..), RawVar (..), MonComponent(..), 
            ppComplexExpr, ppRawExpr, Assignable (..), List2OrMore(..), Consts, ppConsts)

import qualified Core                      as C
import qualified RetCPS                    as CPS


import           Control.Monad.Except
import           Control.Monad.Reader
import           Control.Monad.RWS
import           Control.Monad.State
import           Control.Monad.Writer
import           Data.List
import qualified Data.ByteString           as BS

import           CompileMode
import           Text.PrettyPrint.HughesPJ (hsep, nest, text, vcat, ($$), (<+>))
import qualified Text.PrettyPrint.HughesPJ as PP
import           TroupePositionInfo



data StackBBTree = BB [StackInst] StackTerminator deriving (Eq, Show)



data StackTerminator
  = TailCall RawVar
  | Ret 
  | If RawVar StackBBTree StackBBTree
  | LibExport VarAccess
  | Error RawVar PosInf
  | Call  StackBBTree StackBBTree
  deriving (Eq, Show)



type StackPos = Int
data EscapesBlock = NotEscaping
            | Escaping StackPos
            deriving (Eq, Show)


data RawAssignType = AssignConst | AssignLet | AssignMut deriving (Eq, Ord, Show)


data StackInst
  = AssignRaw RawAssignType RawVar RawExpr
  | LabelGroup [StackInst]
  | AssignLVal VarName ComplexExpr 
  | FetchStack Assignable StackPos
  | StoreStack Assignable StackPos
  | SetState MonComponent RawVar 
  | AssertType RawVar RawType  
  | AssertEqTypes (Maybe (List2OrMore RawType)) RawVar RawVar  -- the list includes an optional list of okay types
  | SetBranchFlag 
  | MkFunClosures [(VarName, VarAccess)] [(VarName, HFN)]
   deriving (Eq, Show)

-- Function definition
data FunDef = FunDef 
                    HFN         -- name of the function     
                    Int         -- frame size     
                    Raw.Consts      -- constant literars
                    StackBBTree    -- body
                    IR.FunDef    -- original definition for serialization
                deriving (Eq)

-- An IR program is just a collection of atoms declarations 
-- and function definitions
data StackProgram = StackProgram C.Atoms [FunDef] 

data StackUnit 
  = FunStackUnit FunDef 
  | AtomStackUnit C.Atoms 
  | ProgramStackUnit StackProgram

-----------------------------------------------------------
-- PRETTY PRINTING
-----------------------------------------------------------

ppProg (StackProgram atoms funs) =
  vcat $ (map ppFunDef funs)

instance Show StackProgram where
  show = PP.render.ppProg

ppFunDef ( FunDef hfn _ consts insts _ )
  = vcat [ text "func" <+> ppFunCall (ppId hfn) [] <+> text "{"
         , nest 2 (ppConsts consts)
         , nest 2 (ppBB insts)
         , text "}"]



qqFields fields =
  PP.hsep $ PP.punctuate (text ",") (map ppField fields)
    where 
      ppField (name, v) = 
        PP.hcat [PP.text name, PP.text "=", ppId v]

ppEsc esc =
  case esc of 
    NotEscaping -> PP.empty
    Escaping x -> PP.text "*" <+> PP.text (show x )


ppIR :: StackInst -> PP.Doc
ppIR SetBranchFlag = text "<setbranchflag>"
ppIR (AssignRaw  _ vn st) = ppId vn <+> text "=" <+> ppRawExpr st
ppIR (AssignLVal vn expr) = 
  ppId vn <+> text "=" <+> ppComplexExpr expr
ppIR (AssertType x t) = text "assert" <+> ppId x <+> text "has type" <+> text (show t)
ppIR (AssertEqTypes Nothing x y) = text "assertEqTypes" <+> ppId x <+> ppId y
ppIR (AssertEqTypes (Just (List2OrMore a1 a2 as)) x y) = text "assertEqTypes" <+> (PP.hsep (map (text.show) (a1:a2:as))) <+> ppId x <+> ppId y
ppIR (SetState comp v) = 
  ppId comp <+> text "<-" <+> ppId v
ppIR (FetchStack x i) = 
  ppId x <+> text "<- $STACK[" PP.<> text (show i) PP.<> text "]"
ppIR (StoreStack x i) = 
  text "$STACK[" PP.<> text (show i) PP.<> text "] = " <+> ppId x 


ppIR (MkFunClosures varmap fdefs) = 
    let vs = hsepc $ ppEnvIds varmap
        ppFdefs = map (\((VN x), HFN y) ->  text x <+> text "= mkClos" <+> text y ) fdefs 
     in text "with env:=" <+> PP.brackets vs $$ nest 2 (vcat ppFdefs)
    where ppEnvIds ls =
            map (\(a,b) -> (ppId a) PP.<+> text "->" <+> ppId b ) ls
          hsepc ls = PP.hsep (PP.punctuate (text ",") ls)

    
ppIR (LabelGroup insts) = 
 text "group" $$ nest 2 (vcat (map ppIR insts))

ppTr (Call bb1 bb2) = (text "= call" $$ nest 2 (ppBB bb1)) $$ (ppBB bb2)


-- ppTr (AssertElseError va ir va2 _) 
--   = text "assert" <+> PP.parens (ppId va) <+>
--     text "{" $$
--     nest 2 (ppBB ir) $$
--     text "}" $$
--     text "elseError" <+> (ppId va2)


ppTr (If va ir1 ir2)
  = text "if" <+> PP.parens (ppId va) <+>
    text "{" $$
    nest 2 (ppBB ir1) $$
    text "}" $$
    text "else {" $$
    nest 2 (ppBB ir2) $$
    text "}"
ppTr (TailCall va1 ) = ppFunCall (text "tail") [ppId va1]
ppTr (Ret)  = ppFunCall (text "ret") []
ppTr (LibExport va) = ppFunCall (text "export") [ppId va]
ppTr (Error va _)  = (text "error") <> (ppId va)


ppBB (BB insts tr) = vcat $ (map ppIR insts) ++ [ppTr tr]



textOfBinOp Basics.LatticeJoin  = "rt.join"
textOfBinOp Basics.LatticeMeet  = "<meet>"
textOfBinOp Basics.Plus = "+"
textOfBinOp Basics.Minus= "-"
textOfBinOp Basics.Mult = "*"
textOfBinOp Basics.Div= "/"
textOfBinOp Basics.Mod = "%"
textOfBinOp Basics.Le= "<="
textOfBinOp Basics.Lt= "<"
textOfBinOp Basics.Ge= ">="
textOfBinOp Basics.Gt= ">"
textOfBinOp Basics.And= "&&"
textOfBinOp Basics.Or= "||"
textOfBinOp Basics.IntDiv= "rt.intdiv"
textOfBinOp Basics.BinAnd = "&"
textOfBinOp Basics.BinOr = "|"
textOfBinOp Basics.BinXor = "^"
textOfBinOp Basics.BinShiftLeft = "<<"
textOfBinOp Basics.BinShiftRight = ">>"
textOfBinOp Basics.BinZeroShiftRight = ">>>"




textOfBinOp Basics.Index = "rt.raw_index"
textOfBinOp x = IR.textOfBinOp x


textOfUnOp Basics.IsTuple = "rt.raw_istuple"
textOfUnOp Basics.Length = "rt.raw_length"
textOfUnOp x = IR.textOfUnOp x