/*
 * This file is part of OpenModelica.
 *
 * Copyright (c) 1998-2014, Open Source Modelica Consortium (OSMC),
 * c/o Linköpings universitet, Department of Computer and Information Science,
 * SE-58183 Linköping, Sweden.
 *
 * All rights reserved.
 *
 * THIS PROGRAM IS PROVIDED UNDER THE TERMS OF GPL VERSION 3 LICENSE OR
 * THIS OSMC PUBLIC LICENSE (OSMC-PL) VERSION 1.2.
 * ANY USE, REPRODUCTION OR DISTRIBUTION OF THIS PROGRAM CONSTITUTES
 * RECIPIENT'S ACCEPTANCE OF THE OSMC PUBLIC LICENSE OR THE GPL VERSION 3,
 * ACCORDING TO RECIPIENTS CHOICE.
 *
 * The OpenModelica software and the Open Source Modelica
 * Consortium (OSMC) Public License (OSMC-PL) are obtained
 * from OSMC, either from the above address,
 * from the URLs: http://www.ida.liu.se/projects/OpenModelica or
 * http://www.openmodelica.org, and in the OpenModelica distribution.
 * GNU version 3 is obtained from: http://www.gnu.org/copyleft/gpl.html.
 *
 * This program is distributed WITHOUT ANY WARRANTY; without
 * even the implied warranty of  MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE, EXCEPT AS EXPRESSLY SET FORTH
 * IN THE BY RECIPIENT SELECTED SUBSIDIARY LICENSE CONDITIONS OF OSMC-PL.
 *
 * See the full OSMC Public License conditions for more details.
 *
 */

encapsulated package BackendDAEOptimize
" file:        BackendDAEOptimize.mo
  package:     BackendDAEOptimize
  description: BackendDAEOptimize contains functions that do some kind of
               optimazation on the BackendDAE datatype:
               - removing simpleEquations
               - Tearing/Relaxation
               - Linearization
               - Inline Integration
               - and so on ...

  RCS: $Id$"

public import Absyn;
public import BackendDAE;
public import DAE;
public import FCore;
public import HashTable2;

protected import Algorithm;
protected import Array;
protected import BackendDAETransform;
protected import BackendDAEUtil;
protected import BackendDump;
protected import BackendEquation;
protected import BackendVarTransform;
protected import BackendVariable;
protected import BaseHashTable;
protected import CheckModel;
protected import ClassInf;
protected import ComponentReference;
protected import DAEUtil;
protected import Debug;
protected import Differentiate;
protected import Expression;
protected import ExpressionSolve;
protected import ExpressionSimplify;
protected import Error;
protected import Flags;
protected import Graph;
protected import HashTableExpToIndex;
protected import List;
protected import RewriteRules;
protected import SCode;
protected import System;
protected import SynchronousFeatures;
protected import Types;
protected import Util;
protected import Values;
protected import ValuesUtil;

// =============================================================================
// simplify time independent function calls
//
// public functions:
//   - simplifyTimeIndepFuncCalls
// =============================================================================

public function simplifyTimeIndepFuncCalls "author: Frenkel TUD 2012-06
  pre(param) -> param
  der(param) -> 0.0
  change(param) -> false
  edge(param) -> false"
  input BackendDAE.BackendDAE inDAE;
  output BackendDAE.BackendDAE outDAE;
algorithm
  (outDAE, _) := BackendDAEUtil.mapEqSystemAndFold(inDAE, simplifyTimeIndepFuncCalls0, false);
  outDAE := simplifyTimeIndepFuncCallsShared(outDAE);
end simplifyTimeIndepFuncCalls;

protected function simplifyTimeIndepFuncCalls0 "author: Frenkel TUD 2012-06"
  input BackendDAE.EqSystem isyst;
  input tuple<BackendDAE.Shared, Boolean> sharedChanged;
  output BackendDAE.EqSystem osyst;
  output tuple<BackendDAE.Shared, Boolean> osharedChanged;
algorithm
  (osyst, osharedChanged) := matchcontinue(isyst, sharedChanged)
    local
      BackendDAE.Variables orderedVars, knvars, aliasvars;
      BackendDAE.EquationArray orderedEqs;
      Option<BackendDAE.IncidenceMatrix> m;
      Option<BackendDAE.IncidenceMatrixT> mT;
      BackendDAE.Matching matching;
      BackendDAE.Shared shared;
      BackendDAE.StateSets stateSets;
      BackendDAE.BaseClockPartitionKind partitionKind;

    case (BackendDAE.EQSYSTEM(orderedVars, orderedEqs, m, mT, matching, stateSets, partitionKind), (shared as BackendDAE.SHARED(knownVars = knvars, aliasVars = aliasvars), _)) equation
      ((_, (_, _, true))) = BackendDAEUtil.traverseBackendDAEExpsEqnsWithUpdate(orderedEqs, Expression.traverseSubexpressionsHelper, (traverserExpsimplifyTimeIndepFuncCalls, (knvars, aliasvars, false)));
    then (BackendDAE.EQSYSTEM(orderedVars, orderedEqs, m, mT, matching, stateSets, partitionKind), (shared, true));

    else (isyst, sharedChanged);
  end matchcontinue;
end simplifyTimeIndepFuncCalls0;

protected function traverserExpsimplifyTimeIndepFuncCalls
  input DAE.Exp inExp;
  input tuple<BackendDAE.Variables, BackendDAE.Variables, Boolean> inTpl;
  output DAE.Exp outExp;
  output tuple<BackendDAE.Variables, BackendDAE.Variables, Boolean> outTpl;
algorithm
  (outExp, outTpl) := matchcontinue (inExp, inTpl)
    local
      BackendDAE.Variables knvars, aliasvars;
      DAE.Type tp;
      DAE.Exp e, zero;
      DAE.ComponentRef cr;
      BackendDAE.Var var;
      DAE.CallAttributes attr;
      Boolean negate;

    case (DAE.CALL(path=Absyn.IDENT(name="der"), expLst={DAE.CREF(componentRef=cr, ty=tp)}), (knvars, aliasvars, _)) equation
      (var::{}, _) = BackendVariable.getVar(cr, knvars);
      false = BackendVariable.isVarOnTopLevelAndInput(var);
      (zero, _) = Expression.makeZeroExpression(Expression.arrayDimension(tp));
    then (zero, (knvars, aliasvars, true));

    case (DAE.CALL(path=Absyn.IDENT(name="pre"), expLst={e as DAE.CREF(componentRef=cr)}), (knvars, aliasvars, _)) equation
      (_::{}, _) = BackendVariable.getVar(cr, knvars);
    then(e, (knvars, aliasvars, true));

    case (DAE.CALL(path=Absyn.IDENT(name="pre"), expLst={e as DAE.CREF(componentRef=DAE.CREF_IDENT(ident="time"))}), (knvars, aliasvars, _))
    then (e, (knvars, aliasvars, true));

    case (DAE.CALL(path=Absyn.IDENT(name="pre"), expLst={e as DAE.UNARY(DAE.UMINUS(_), DAE.CREF(componentRef=DAE.CREF_IDENT(ident="time")))}), (knvars, aliasvars, _))
    then (e, (knvars, aliasvars, true));

    case (DAE.CALL(path=Absyn.IDENT(name="pre"), expLst={DAE.CREF(componentRef=cr, ty=tp)}, attr=attr), (knvars, aliasvars, _)) equation
      (var::{}, _) = BackendVariable.getVar(cr, aliasvars);
      (cr, negate) = BackendVariable.getAlias(var);
      e = DAE.CREF(cr, tp);
      e = if negate then Expression.negate(e) else e;
      (e, _) = ExpressionSimplify.simplify(DAE.CALL(Absyn.IDENT("pre"), {e}, attr));
      (e, _) = Expression.traverseExp(e, traverserExpsimplifyTimeIndepFuncCalls, (knvars, aliasvars, false));
    then (e, (knvars, aliasvars, true));

    case (DAE.CALL(path=Absyn.IDENT(name="change"), expLst={DAE.CREF(componentRef=cr, ty=tp)}), (knvars, aliasvars, _)) equation
      (_::_, _) = BackendVariable.getVar(cr, knvars);
      zero = Expression.arrayFill(Expression.arrayDimension(tp), DAE.BCONST(false));
    then (zero, (knvars, aliasvars, true));

    case (DAE.CALL(path=Absyn.IDENT(name="change"), expLst={DAE.CREF(componentRef=cr, ty=tp)}), (knvars, aliasvars, _)) equation
      (_::_, _) = BackendVariable.getVar(cr, aliasvars);
      zero = Expression.arrayFill(Expression.arrayDimension(tp), DAE.BCONST(false));
    then (zero, (knvars, aliasvars, true));

    case (DAE.CALL(path=Absyn.IDENT(name="change"), expLst={DAE.CREF(componentRef=DAE.CREF_IDENT(ident="time"))}), (knvars, aliasvars, _))
    then (DAE.BCONST(false), (knvars, aliasvars, true));

    case (DAE.CALL(path=Absyn.IDENT(name="change"), expLst={DAE.CREF(componentRef=cr, ty=tp)}, attr=attr), (knvars, aliasvars, _)) equation
      (var::{}, _) = BackendVariable.getVar(cr, aliasvars);
      (cr, negate) = BackendVariable.getAlias(var);
      e = DAE.CREF(cr, tp);
      e = if negate then Expression.negate(e) else e;
      (e, _) = ExpressionSimplify.simplify(DAE.CALL(Absyn.IDENT("change"), {e}, attr));
      (e, _) = Expression.traverseExp(e, traverserExpsimplifyTimeIndepFuncCalls, (knvars, aliasvars, false));
    then (e, (knvars, aliasvars, true));

    case (DAE.CALL(path=Absyn.IDENT(name="edge"), expLst={DAE.CREF(componentRef=cr, ty=tp)}), (knvars, aliasvars, _)) equation
      (_::{}, _) = BackendVariable.getVar(cr, knvars);
      zero = Expression.arrayFill(Expression.arrayDimension(tp), DAE.BCONST(false));
    then (zero, (knvars, aliasvars, true));

    case (DAE.CALL(path=Absyn.IDENT(name="edge"), expLst={DAE.CREF(componentRef=DAE.CREF_IDENT(ident="time"))}), (knvars, aliasvars, _))
    then (DAE.BCONST(false), (knvars, aliasvars, true));

    case (DAE.CALL(path=Absyn.IDENT(name="edge"), expLst={DAE.CREF(componentRef=cr, ty=tp)}, attr=attr), (knvars, aliasvars, _)) equation
      (var::{}, _) = BackendVariable.getVar(cr, aliasvars);
      (cr, negate) = BackendVariable.getAlias(var);
      e = DAE.CREF(cr, tp);
      e = if negate then Expression.negate(e) else e;
      (e, _) = ExpressionSimplify.simplify(DAE.CALL(Absyn.IDENT("edge"), {e}, attr));
      (e, _) = Expression.traverseExp(e, traverserExpsimplifyTimeIndepFuncCalls, (knvars, aliasvars, false));
    then (e, (knvars, aliasvars, true));

    else (inExp, inTpl);
  end matchcontinue;
end traverserExpsimplifyTimeIndepFuncCalls;

protected function simplifyTimeIndepFuncCallsShared "pre(param) -> param
  der(param) -> 0.0
  change(param) -> false
  edge(param) -> false
  author: Frenkel TUD 2012-06"
  input BackendDAE.BackendDAE inDAE;
  output BackendDAE.BackendDAE outDAE;
protected
  BackendDAE.Variables knvars, exobj, aliasVars;
  BackendDAE.EquationArray remeqns, inieqns;
  list<DAE.Constraint> constrs;
  list<DAE.ClassAttributes> clsAttrs;
  FCore.Cache cache;
  FCore.Graph graph;
  DAE.FunctionTree funcTree;
  BackendDAE.ExternalObjectClasses eoc;
  BackendDAE.SymbolicJacobians symjacs;
  BackendDAE.EventInfo eventInfo;
  BackendDAE.BackendDAEType btp;
  BackendDAE.EqSystems systs;
  BackendDAE.ExtraInfo ei;
algorithm
  BackendDAE.DAE(systs, BackendDAE.SHARED(knvars, exobj, aliasVars, inieqns, remeqns, constrs, clsAttrs, cache, graph, funcTree, eventInfo, eoc, btp, symjacs, ei)) := inDAE;

  _ := BackendDAEUtil.traverseBackendDAEExpsVarsWithUpdate(knvars, Expression.traverseSubexpressionsHelper, (traverserExpsimplifyTimeIndepFuncCalls, (knvars, aliasVars, false)));
  _ := BackendDAEUtil.traverseBackendDAEExpsEqnsWithUpdate(inieqns, Expression.traverseSubexpressionsHelper, (traverserExpsimplifyTimeIndepFuncCalls, (knvars, aliasVars, false)));
  _ := BackendDAEUtil.traverseBackendDAEExpsEqnsWithUpdate(remeqns, Expression.traverseSubexpressionsHelper, (traverserExpsimplifyTimeIndepFuncCalls, (knvars, aliasVars, false)));
  (eventInfo, _) := traverseEventInfoExps(eventInfo, Expression.traverseSubexpressionsHelper, (traverserExpsimplifyTimeIndepFuncCalls, (knvars, aliasVars, false)));

  outDAE := BackendDAE.DAE(systs, BackendDAE.SHARED(knvars, exobj, aliasVars, inieqns, remeqns, constrs, clsAttrs, cache, graph, funcTree, eventInfo, eoc, btp, symjacs, ei));
end simplifyTimeIndepFuncCallsShared;

protected function traverseEventInfoExps<T>
  input BackendDAE.EventInfo iEventInfo;
  input FuncExpType func;
  input T inTypeA;
  output BackendDAE.EventInfo oEventInfo;
  output T outTypeA;
  partial function FuncExpType
    input DAE.Exp inExp;
    input T inTypeA;
    output DAE.Exp outExp;
    output T outA;
  end FuncExpType;
protected
  list<BackendDAE.TimeEvent> timeEvents;
  list<BackendDAE.WhenClause> whenClauseLst;
  list<BackendDAE.ZeroCrossing> zeroCrossingLst, sampleLst, relationsLst;
  Integer numberMathEvents;
algorithm
  BackendDAE.EVENT_INFO(timeEvents, whenClauseLst, zeroCrossingLst, sampleLst, relationsLst, numberMathEvents) := iEventInfo;
  (whenClauseLst, outTypeA) := traverseWhenClauseExps(whenClauseLst, func, inTypeA, {});
  (zeroCrossingLst, outTypeA) := traverseZeroCrossingExps(zeroCrossingLst, func, outTypeA, {});
  (sampleLst, outTypeA) := traverseZeroCrossingExps(sampleLst, func, outTypeA, {});
  (relationsLst, outTypeA) := traverseZeroCrossingExps(relationsLst, func, outTypeA, {});
  oEventInfo := BackendDAE.EVENT_INFO(timeEvents, whenClauseLst, zeroCrossingLst, sampleLst, relationsLst, numberMathEvents);
end traverseEventInfoExps;

protected function traverseWhenClauseExps<T>
  input list<BackendDAE.WhenClause> iWhenClauses;
  input FuncExpType func;
  input T inTypeA;
  input list<BackendDAE.WhenClause> iAcc;
  output list<BackendDAE.WhenClause> oWhenClauses;
  output T outTypeA;
  partial function FuncExpType
    input DAE.Exp inExp;
    input T inTypeA;
    output DAE.Exp outExp;
    output T outA;
  end FuncExpType;
algorithm
  (oWhenClauses, outTypeA) := match (iWhenClauses)
    local
      list<BackendDAE.WhenClause> whenClause;
      DAE.Exp condition;
      list<BackendDAE.WhenOperator> reinitStmtLst;
      Option<Integer> elseClause;
      T arg;

    case {}
    then (listReverse(iAcc), inTypeA);

    case BackendDAE.WHEN_CLAUSE(condition, reinitStmtLst, elseClause)::whenClause equation
      (condition, arg) = Expression.traverseExp(condition, func, inTypeA);
      (whenClause, arg) = traverseWhenClauseExps(whenClause, func, arg, BackendDAE.WHEN_CLAUSE(condition, reinitStmtLst, elseClause)::iAcc);
    then (whenClause, arg);
  end match;
end traverseWhenClauseExps;

protected function traverseZeroCrossingExps<T>
  input list<BackendDAE.ZeroCrossing> iZeroCrossing;
  input FuncExpType func;
  input T inTypeA;
  input list<BackendDAE.ZeroCrossing> iAcc;
  output list<BackendDAE.ZeroCrossing> oZeroCrossing;
  output T outTypeA;
  partial function FuncExpType
    input DAE.Exp inExp;
    input T inTypeA;
    output DAE.Exp outExp;
    output T outA;
  end FuncExpType;
algorithm
  (oZeroCrossing, outTypeA) := match (iZeroCrossing)
    local
      list<BackendDAE.ZeroCrossing> zeroCrossing;
      DAE.Exp relation_;
      list<Integer> occurEquLst,occurWhenLst;
      T arg;

    case {}
    then (listReverse(iAcc), inTypeA);

    case BackendDAE.ZERO_CROSSING(relation_, occurEquLst, occurWhenLst)::zeroCrossing equation
      (relation_, arg) = Expression.traverseExp(relation_, func, inTypeA);
      (zeroCrossing, arg) = traverseZeroCrossingExps(zeroCrossing, func, arg, BackendDAE.ZERO_CROSSING(relation_, occurEquLst, occurWhenLst)::iAcc);
    then (zeroCrossing, arg);
  end match;
end traverseZeroCrossingExps;

// =============================================================================
// =============================================================================

protected function traverseIncidenceMatrix "author: Frenkel TUD 2010-12"
  replaceable type Type_a subtypeof Any;
  input BackendDAE.IncidenceMatrix inM;
  input FuncType func;
  input Type_a inTypeA;
  output BackendDAE.IncidenceMatrix outM;
  output Type_a outTypeA;
  partial function FuncType
    input tuple<BackendDAE.IncidenceMatrixElement,Integer,BackendDAE.IncidenceMatrix,Type_a> inTpl;
    output tuple<list<Integer>,BackendDAE.IncidenceMatrix,Type_a> outTpl;
  end FuncType;
algorithm
  (outM,outTypeA) := traverseIncidenceMatrix1(inM,func,1,arrayLength(inM),inTypeA);
end traverseIncidenceMatrix;

protected function traverseIncidenceMatrix1 "author: Frenkel TUD 2010-12"
  replaceable type Type_a subtypeof Any;
  input BackendDAE.IncidenceMatrix inM;
  input FuncType func;
  input Integer pos "iterated 1..len";
  input Integer len "length of array";
  input Type_a inTypeA;
  output BackendDAE.IncidenceMatrix outM;
  output Type_a outTypeA;
  partial function FuncType
    input tuple<BackendDAE.IncidenceMatrixElement,Integer,BackendDAE.IncidenceMatrix,Type_a> inTpl;
    output tuple<list<Integer>,BackendDAE.IncidenceMatrix,Type_a> outTpl;
  end FuncType;
algorithm
  (outM,outTypeA) := traverseIncidenceMatrix2(inM,func,pos,len,intGt(pos,len),inTypeA);
  annotation(__OpenModelica_EarlyInline = true);
end traverseIncidenceMatrix1;

protected function traverseIncidenceMatrix2
"  author: Frenkel TUD 2010-12"
  replaceable type Type_a subtypeof Any;
  input BackendDAE.IncidenceMatrix inM;
  input FuncType func;
  input Integer pos "iterated 1..len";
  input Integer len "length of array";
  input Boolean stop;
  input Type_a inTypeA;
  output BackendDAE.IncidenceMatrix outM;
  output Type_a outTypeA;
  partial function FuncType
    input tuple<BackendDAE.IncidenceMatrixElement,Integer,BackendDAE.IncidenceMatrix,Type_a> inTpl;
    output tuple<list<Integer>,BackendDAE.IncidenceMatrix,Type_a> outTpl;
  end FuncType;
algorithm
  (outM,outTypeA) := match (inM,func,pos,len,stop,inTypeA)
    local
      BackendDAE.IncidenceMatrix m,m1,m2;
      Type_a extArg,extArg1,extArg2;
      list<Integer> eqns,eqns1;

    case(_,_,_,_,true,_)
    then (inM,inTypeA);

    case(_,_,_,_,false,_)
      equation
        ((eqns,m,extArg)) = func((inM[pos],pos,inM,inTypeA));
        eqns1 = List.removeOnTrue(pos,intLt,eqns);
        (m1,extArg1) = traverseIncidenceMatrixList(eqns1,m,func,arrayLength(m),pos,extArg);
        (m2,extArg2) = traverseIncidenceMatrix2(m1,func,pos+1,len,intGt(pos+1,len),extArg1);
      then (m2,extArg2);

  end match;
end traverseIncidenceMatrix2;

protected function traverseIncidenceMatrixList
"  author: Frenkel TUD 2011-04"
  replaceable type Type_a subtypeof Any;
  input list<Integer> inLst "elements to traverse";
  input BackendDAE.IncidenceMatrix inM;
  input FuncType func;
  input Integer len "length of array";
  input Integer maxpos "do not go further than this position";
  input Type_a inTypeA;
  output BackendDAE.IncidenceMatrix outM;
  output Type_a outTypeA;
  partial function FuncType
    input tuple<BackendDAE.IncidenceMatrixElement,Integer,BackendDAE.IncidenceMatrix,Type_a> inTpl;
    output tuple<list<Integer>,BackendDAE.IncidenceMatrix,Type_a> outTpl;
  end FuncType;
algorithm
  (outM,outTypeA) := matchcontinue(inLst,inM,func,len,maxpos,inTypeA)
    local
      BackendDAE.IncidenceMatrix m,m1;
      Type_a extArg,extArg1;
      list<Integer> rest,eqns,eqns1,alleqns;
      Integer pos;

    case({},_,_,_,_,_) then (inM,inTypeA);

    case(pos::rest,_,_,_,_,_) equation
      // do not leave the list
      true = intLt(pos,len+1);
      // do not more than necesary
      true = intLt(pos,maxpos);
      ((eqns,m,extArg)) = func((inM[pos],pos,inM,inTypeA));
      eqns1 = List.removeOnTrue(maxpos,intLt,eqns);
      alleqns = List.unionOnTrueList({rest, eqns1},intEq);
      (m1,extArg1) = traverseIncidenceMatrixList(alleqns,m,func,len,maxpos,extArg);
    then (m1,extArg1);

    case(pos::rest,_,_,_,_,_) equation
      // do not leave the list
      true = intLt(pos,len+1);
      (m,extArg) = traverseIncidenceMatrixList(rest,inM,func,len,maxpos,inTypeA);
    then (m,extArg);

    case (_,_,_,_,_,_)
      equation
        true = Flags.isSet(Flags.FAILTRACE);
        Debug.trace("- BackendDAEOptimize.traverseIncidenceMatrixList failed\n");
      then
        fail();
  end matchcontinue;
end traverseIncidenceMatrixList;

protected function toplevelInputOrUnfixed
  input BackendDAE.Var inVar;
  output Boolean b;
algorithm
  b := BackendVariable.isVarOnTopLevelAndInput(inVar) or
       BackendVariable.isParam(inVar) and not BackendVariable.varFixed(inVar);
end toplevelInputOrUnfixed;

protected function traversingTimeEqnsFinder "author: Frenkel 2010-12"
  input DAE.Exp inExp;
  input tuple<Boolean,BackendDAE.Variables,BackendDAE.Variables,Boolean,Boolean> inTpl;
  output DAE.Exp outExp;
  output Boolean cont;
  output tuple<Boolean,BackendDAE.Variables,BackendDAE.Variables,Boolean,Boolean> outTpl;
algorithm
  (outExp,cont,outTpl) := matchcontinue (inExp,inTpl)
    local
      DAE.Exp e;
      Boolean b,b1,b2;
      BackendDAE.Variables vars,knvars;
      DAE.ComponentRef cr;
      BackendDAE.Var var;
      list<BackendDAE.Var> vlst;

    case (e as DAE.CREF(DAE.CREF_IDENT(ident = "time",subscriptLst = {}),_), (_,vars,knvars,b1,b2))
      then (e,false,(true,vars,knvars,b1,b2));
    // inputs not constant and parameter(fixed=false) are constant but evaluated after konstant variables are evaluted
    case (e as DAE.CREF(cr,_), (_,vars,knvars,b1,b2))
      equation
        (vlst,_::_)= BackendVariable.getVar(cr, knvars) "input variables stored in known variables are input on top level";
        false = List.mapAllValueBool(vlst,toplevelInputOrUnfixed,false);
      then (e,false,(true,vars,knvars,b1,b2));
    case (e as DAE.CALL(path = Absyn.IDENT(name = "sample"), expLst = {_,_,_}), (_,vars,knvars,b1,b2)) then (e,false,(true,vars,knvars,b1,b2));
    case (e as DAE.CALL(path = Absyn.IDENT(name = "pre"), expLst = {_}), (_,vars,knvars,b1,b2)) then (e,false,(true,vars,knvars,b1,b2));
    case (e as DAE.CALL(path = Absyn.IDENT(name = "change"), expLst = {_}), (_,vars,knvars,b1,b2)) then (e,false,(true,vars,knvars,b1,b2));
    case (e as DAE.CALL(path = Absyn.IDENT(name = "edge"), expLst = {_}), (_,vars,knvars,b1,b2)) then (e,false,(true,vars,knvars,b1,b2));
    // case for finding simple equation in jacobians
    // there are all known variables mark as input
    // and they are all time-depending
    case (e as DAE.CREF(cr,_), (_,vars,knvars,true,b2))
      equation
        (var::_,_::_)= BackendVariable.getVar(cr, knvars);
        DAE.INPUT() = BackendVariable.getVarDirection(var);
      then (e,false,(true,vars,knvars,true,b2));
    // unkown var
    case (e as DAE.CREF(cr,_), (_,vars,knvars,b1,true))
      equation
        (_::_,_::_)= BackendVariable.getVar(cr, vars);
      then (e,false,(true,vars,knvars,b1,true));
    case (e,(b,vars,knvars,b1,b2)) then (e,not b,(b,vars,knvars,b1,b2));

  end matchcontinue;
end traversingTimeEqnsFinder;

public function countSimpleEquations
"author: Frenkel TUD 2011-05
  This function count the simple equations on the form a=b and a=const and a=f(not time)
  in BackendDAE.BackendDAE. Note this functions does not use variable replacements, because
  of this the number of simple equations is maybe smaller than using variable replacements."
  input BackendDAE.BackendDAE inDlow;
  input BackendDAE.IncidenceMatrix inM;
  output Integer outSimpleEqns;
algorithm
  outSimpleEqns:=
  match (inDlow,inM)
    local
      BackendDAE.BackendDAE dlow;
      BackendDAE.EquationArray eqns;
      Integer n;
    case (dlow,_)
      equation
        // check equations
       (_,(_,n)) = traverseIncidenceMatrix(inM,countSimpleEquationsFinder,(dlow,0));
      then n;
  end match;
end countSimpleEquations;

protected function countSimpleEquationsFinder
"author: Frenkel TUD 2011-05"
 input tuple<BackendDAE.IncidenceMatrixElement,Integer,BackendDAE.IncidenceMatrix, tuple<BackendDAE.BackendDAE,Integer>> inTpl;
 output tuple<list<Integer>,BackendDAE.IncidenceMatrix, tuple<BackendDAE.BackendDAE,Integer>> outTpl;
algorithm
  outTpl:=
  matchcontinue (inTpl)
    local
      BackendDAE.IncidenceMatrixElement elem;
      Integer pos,l,i,n,n_1;
      BackendDAE.IncidenceMatrix m;
      BackendDAE.BackendDAE dae;
      BackendDAE.EqSystem syst;
      BackendDAE.Shared shared;

    case ((elem,pos,m,(dae as BackendDAE.DAE({syst},shared),n)))
      equation
        // check number of vars in eqns
        l = listLength(elem);
        true = intLt(l,3);
        true = intGt(l,0);
        countsimpleEquation(elem,l,pos,syst,shared);
        n_1 = n+1;
      then (({},m,(dae,n_1)));
    case ((_,_,m,(dae,n)))
      then (({},m,(dae,n)));
  end matchcontinue;
end countSimpleEquationsFinder;

protected function countsimpleEquation
"  author: Frenkel TUD 2011-05"
  input BackendDAE.IncidenceMatrixElement elem;
  input Integer length;
  input Integer pos;
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
algorithm
  _ := matchcontinue(elem,length,pos,syst,shared)
    local
      DAE.ComponentRef cr;
      Integer i,j;
      DAE.Exp es,cre,e1,e2;
      BackendDAE.Variables vars,knvars;
      BackendDAE.Var var;
      BackendDAE.EquationArray eqns;
      BackendDAE.Equation eqn;
      Boolean negate;
      DAE.ElementSource source;
    // a = const
    // wbraun:
    // speacial case for Jacobains, since there are all known variablen
    // time depending input variables
    case ({i},_,_,_,BackendDAE.SHARED(backendDAEType = BackendDAE.JACOBIAN()))
      equation
        vars = BackendVariable.daeVars(syst);
        var = BackendVariable.getVarAt(vars,intAbs(i));
        // no State
        false = BackendVariable.isStateorStateDerVar(var);
        // try to solve the equation
        eqns = BackendEquation.getEqnsFromEqSystem(syst);
        eqn = BackendEquation.equationNth1(eqns,pos);
        BackendDAE.EQUATION(exp=e1,scalar=e2) = eqn;
        // variable time not there
        knvars = BackendVariable.daeKnVars(shared);
        (_,(false,_,_,_,_)) = Expression.traverseExpTopDown(e1, traversingTimeEqnsFinder, (false,vars,knvars,true,false));
        (_,(false,_,_,_,_)) = Expression.traverseExpTopDown(e2, traversingTimeEqnsFinder, (false,vars,knvars,true,false));
        cr = BackendVariable.varCref(var);
        cre = Expression.crefExp(cr);
        (_,{}) = ExpressionSolve.solve(e1,e2,cre);
      then ();
    // a = const
    case ({i},_,_,_,_)
      equation
        vars = BackendVariable.daeVars(syst);
        var = BackendVariable.getVarAt(vars,intAbs(i));
        // no State
        false = BackendVariable.isStateorStateDerVar(var);
        // try to solve the equation
        eqns = BackendEquation.getEqnsFromEqSystem(syst);
        eqn = BackendEquation.equationNth1(eqns,pos);
        BackendDAE.EQUATION(exp=e1,scalar=e2) = eqn;
        // variable time not there
        knvars = BackendVariable.daeKnVars(shared);
        (_,(false,_,_,_,_)) = Expression.traverseExpTopDown(e1, traversingTimeEqnsFinder, (false,vars,knvars,false,false));
        (_,(false,_,_,_,_)) = Expression.traverseExpTopDown(e2, traversingTimeEqnsFinder, (false,vars,knvars,false,false));
        cr = BackendVariable.varCref(var);
        cre = Expression.crefExp(cr);
        (_,{}) = ExpressionSolve.solve(e1,e2,cre);
      then ();
    // a = der(b)
    case ({_,_},_,_,_,_)
      equation
        eqns = BackendEquation.getEqnsFromEqSystem(syst);
        eqn = BackendEquation.equationNth1(eqns,pos);
        (cr,_,_,_,_) = BackendEquation.derivativeEquation(eqn);
        // select candidate
        vars = BackendVariable.daeVars(syst);
        ((_::_),(_::_)) = BackendVariable.getVar(cr,vars);
      then ();
    // a = b
    case ({_,_},_,_,_,_)
      equation
        eqns = BackendEquation.getEqnsFromEqSystem(syst);
        (eqn as BackendDAE.EQUATION()) = BackendEquation.equationNth1(eqns,pos);
        _ = BackendEquation.aliasEquation(eqn);
      then ();
  end matchcontinue;
end countsimpleEquation;

// =============================================================================
// remove parameters stuff
//
// =============================================================================
public function removeParameters
"author wbraun"
  input BackendDAE.BackendDAE inDAE;
  output BackendDAE.BackendDAE outDAE;
algorithm
  outDAE := match (inDAE)
    local
      BackendDAE.Variables knvars,exobj,knvars1,av;
      BackendDAE.EquationArray remeqns,inieqns;
      list<DAE.Constraint> constrs;
      list<DAE.ClassAttributes> clsAttrs;
      FCore.Cache cache;
      FCore.Graph graph;
      DAE.FunctionTree funcs;
      BackendDAE.EventInfo einfo;
      BackendDAE.ExternalObjectClasses eoc;
      BackendDAE.SymbolicJacobians symjacs;
      BackendVarTransform.VariableReplacements repl,repl1,repl2;
      BackendDAE.BackendDAEType btp;
      BackendDAE.EqSystems systs;
      BackendDAE.ExtraInfo ei;

    case (BackendDAE.DAE(systs,BackendDAE.SHARED(knvars,exobj,av,inieqns,remeqns,constrs,clsAttrs,cache,graph,funcs,einfo,eoc,btp,symjacs,ei)))
      equation
        repl = BackendVarTransform.emptyReplacements();
        ((repl1,_)) = BackendVariable.traverseBackendDAEVars(knvars,removeParametersFinder,(repl,knvars));
        (knvars1,repl2) = replaceFinalVars(1,knvars,repl1);
        (knvars1,repl2) = replaceFinalVars(1,knvars1,repl2);
        if Flags.isSet(Flags.DUMP_PARAM_REPL) then
         BackendVarTransform.dumpReplacements(repl2);
        end if;
        systs= List.map1(systs,removeParameterswork,repl2);
      then
        BackendDAE.DAE(systs,BackendDAE.SHARED(knvars1,exobj,av,inieqns,remeqns,constrs,clsAttrs,cache,graph,funcs,einfo,eoc,btp,symjacs,ei));
  end match;
end removeParameters;

protected function removeParameterswork
"author wbraun"
  input BackendDAE.EqSystem isyst;
  input BackendVarTransform.VariableReplacements repl;
  output BackendDAE.EqSystem osyst;
algorithm
  osyst := match (isyst,repl)
    local
      Option<BackendDAE.IncidenceMatrix> m,mT;
      BackendDAE.Variables vars;
      BackendDAE.EquationArray eqns,eqns1;
      list<BackendDAE.Equation> eqns_1,lsteqns;
      BackendDAE.Matching matching;
      BackendDAE.StateSets stateSets;
      BackendDAE.BaseClockPartitionKind partitionKind;

    case (BackendDAE.EQSYSTEM(vars,eqns,_,_,matching,stateSets,partitionKind),_)
      equation
        lsteqns = BackendEquation.equationList(eqns);
        (vars,_) = replaceFinalVars(1,vars,repl); // replacing variable attributes (e.g start) in unknown vars
        (eqns_1,_) = BackendVarTransform.replaceEquations(lsteqns, repl,NONE());
        eqns1 = BackendEquation.listEquation(eqns_1);
      then
        BackendDAE.EQSYSTEM(vars,eqns1,NONE(),NONE(),matching,stateSets,partitionKind);
  end match;
end removeParameterswork;

protected function removeParametersFinder
  input BackendDAE.Var inVar;
  input tuple<BackendVarTransform.VariableReplacements,BackendDAE.Variables> inTpl;
  output BackendDAE.Var outVar;
  output tuple<BackendVarTransform.VariableReplacements,BackendDAE.Variables> outTpl;
algorithm
  (outVar,outTpl) := matchcontinue (inVar,inTpl)
    local
      BackendDAE.Variables vars;
      BackendDAE.Var v;
      BackendVarTransform.VariableReplacements repl,repl_1;
      DAE.ComponentRef varName;
      Option< .DAE.VariableAttributes> values;
      DAE.Exp exp,exp1;
      Values.Value bindValue;

    case (v as BackendDAE.VAR(varName=varName,varKind=BackendDAE.PARAM(),bindExp=SOME(exp)),(repl,vars))
      equation
        (exp1, _) = Expression.traverseExp(exp, BackendDAEUtil.replaceCrefsWithValues, (vars, varName));
        repl_1 = BackendVarTransform.addReplacement(repl, varName, exp1,NONE());
      then (v,(repl_1,vars));

    case (v as BackendDAE.VAR(varName=varName,varKind=BackendDAE.PARAM(),bindValue=SOME(bindValue)),(repl,vars))
      equation
        exp = ValuesUtil.valueExp(bindValue);
        repl_1 = BackendVarTransform.addReplacement(repl, varName, exp,NONE());
      then (v,(repl_1,vars));

    else (inVar,inTpl);
  end matchcontinue;
end removeParametersFinder;

protected function replaceFinalVars
"  author: Frenkel TUD 2011-04"
  input Integer inNumRepl;
  input BackendDAE.Variables inVars;
  input BackendVarTransform.VariableReplacements inRepl;
  output BackendDAE.Variables outVars;
  output BackendVarTransform.VariableReplacements outRepl;
algorithm
  (outVars,outRepl) := matchcontinue(inNumRepl,inVars,inRepl)
    local
      Integer numrepl;
      BackendDAE.Variables knvars,knvars1,knvars2;
      BackendVarTransform.VariableReplacements repl,repl1,repl2;

    case(numrepl,knvars,repl)
      equation
      true = intEq(0,numrepl);
    then (knvars,repl);

    case(numrepl,knvars,repl)
      equation
      (knvars1,(repl1,numrepl)) = BackendVariable.traverseBackendDAEVarsWithUpdate(knvars,replaceFinalVarTraverser,(repl,0));
      (knvars2,repl2) = replaceFinalVars(numrepl,knvars1,repl1);
    then (knvars2,repl2);

  end matchcontinue;
end replaceFinalVars;


protected function replaceFinalVarTraverser
  input BackendDAE.Var inVar;
  input tuple<BackendVarTransform.VariableReplacements,Integer> inTpl;
  output BackendDAE.Var outVar;
  output tuple<BackendVarTransform.VariableReplacements,Integer> outTpl;
algorithm
  (outVar,outTpl) := matchcontinue (inVar,inTpl)
    local
      BackendDAE.Var v,v1;
      BackendVarTransform.VariableReplacements repl,repl_1;
      Integer numrepl;
      DAE.Exp e,e1;
      DAE.ComponentRef cr;
      Option<DAE.VariableAttributes> attr,new_attr;

    case (v as BackendDAE.VAR(varName=cr,bindExp=SOME(e),values=attr),(repl,numrepl))
      equation
        (e1,true) = BackendVarTransform.replaceExp(e, repl, NONE());
        (e1,_) = ExpressionSimplify.simplify(e1);
        v1 = BackendVariable.setBindExp(v, SOME(e1));
        repl_1 = addConstExpReplacement(e1,cr,repl);
        (attr,repl_1) = BackendDAEUtil.traverseBackendDAEVarAttr(attr,traverseExpVisitorWrapper,repl_1);
        v1 = BackendVariable.setVarAttributes(v1,attr);
      then (v1,(repl_1,numrepl+1));

    case (v as BackendDAE.VAR(values=attr),(repl,numrepl))
      equation
        (new_attr,repl) = BackendDAEUtil.traverseBackendDAEVarAttr(attr,traverseExpVisitorWrapper,repl);
        v1 = BackendVariable.setVarAttributes(v,new_attr);
      then (v1,(repl,numrepl));
  end matchcontinue;
end replaceFinalVarTraverser;

protected function addConstExpReplacement
  input DAE.Exp inExp;
  input DAE.ComponentRef cr;
  input BackendVarTransform.VariableReplacements inRepl;
  output BackendVarTransform.VariableReplacements outRepl;
algorithm
  outRepl := matchcontinue(inExp,cr,inRepl)
    case (_,_,_)
      equation
        true = Expression.isConst(inExp);
      then
        BackendVarTransform.addReplacement(inRepl, cr, inExp,NONE());
    else
      inRepl;
  end matchcontinue;
end addConstExpReplacement;

protected function traverseExpVisitorWrapper "help function to replaceFinalVarTraverser"
  input DAE.Exp inExp;
  input BackendVarTransform.VariableReplacements inRepl;
  output DAE.Exp exp;
  output BackendVarTransform.VariableReplacements repl;
algorithm
  (exp,repl) := matchcontinue(inExp,inRepl)
    local
      DAE.ComponentRef cr;

    case (exp as DAE.CREF(_,_),repl) equation
      (exp,_) = BackendVarTransform.replaceExp(exp,repl,NONE());
    then (exp,repl);

    else (inExp,inRepl);
  end matchcontinue;
end traverseExpVisitorWrapper;


// =============================================================================
// remove protected parameters stuff
//
// =============================================================================
public function removeProtectedParameters
"author Frenkel TUD"
  input BackendDAE.BackendDAE inDAE;
  output BackendDAE.BackendDAE outDAE;
algorithm
  outDAE := match (inDAE)
    local
      DAE.FunctionTree funcs;
      BackendDAE.Variables knvars,exobj,av;
      BackendDAE.EquationArray remeqns,inieqns;
      list<DAE.Constraint> constrs;
      list<DAE.ClassAttributes> clsAttrs;
      FCore.Cache cache;
      FCore.Graph graph;
      BackendDAE.EventInfo einfo;
      BackendDAE.ExternalObjectClasses eoc;
      BackendDAE.SymbolicJacobians symjacs;
      BackendVarTransform.VariableReplacements repl,repl1;
      BackendDAE.BackendDAEType btp;
      BackendDAE.EqSystems systs;
      BackendDAE.ExtraInfo ei;

    case (BackendDAE.DAE(systs,BackendDAE.SHARED(knvars,exobj,av,inieqns,remeqns,constrs,clsAttrs,cache,graph,funcs,einfo,eoc,btp,symjacs,ei)))
      equation
        repl = BackendVarTransform.emptyReplacements();
        repl1 = BackendVariable.traverseBackendDAEVars(knvars,protectedParametersFinder,repl);
        if Flags.isSet(Flags.DUMP_PP_REPL) then
          BackendVarTransform.dumpReplacements(repl1);
        end if;
        systs = List.map1(systs,removeProtectedParameterswork,repl1);
      then
        (BackendDAE.DAE(systs,BackendDAE.SHARED(knvars,exobj,av,inieqns,remeqns,constrs,clsAttrs,cache,graph,funcs,einfo,eoc,btp,symjacs,ei)));
  end match;
end removeProtectedParameters;

protected function removeProtectedParameterswork
"author Frenkel TUD"
  input BackendDAE.EqSystem isyst;
  input BackendVarTransform.VariableReplacements repl;
  output BackendDAE.EqSystem osyst;
algorithm
  osyst := match (isyst,repl)
    local
      BackendDAE.EqSystem syst;
      BackendDAE.Variables vars;
      BackendDAE.EquationArray eqns,eqns1;
      list<BackendDAE.Equation> eqns_1,lsteqns;
      Boolean b;
      BackendDAE.StateSets stateSets;
      BackendDAE.BaseClockPartitionKind partitionKind;

    case (BackendDAE.EQSYSTEM(orderedVars=vars,orderedEqs=eqns,stateSets=stateSets,partitionKind=partitionKind),_)
      equation
        lsteqns = BackendEquation.equationList(eqns);
        (eqns_1,b) = BackendVarTransform.replaceEquations(lsteqns, repl,NONE());
        eqns1 = if b then BackendEquation.listEquation(eqns_1) else eqns;
        syst = if b then BackendDAE.EQSYSTEM(vars,eqns1,NONE(),NONE(),BackendDAE.NO_MATCHING(),stateSets,partitionKind) else isyst;
      then
        syst;
  end match;
end removeProtectedParameterswork;

protected function protectedParametersFinder
  input BackendDAE.Var inVar;
  input BackendVarTransform.VariableReplacements inRepl;
  output BackendDAE.Var outVar;
  output BackendVarTransform.VariableReplacements outRepl;
algorithm
  (outVar,outRepl) := matchcontinue (inVar,inRepl)
    local
      BackendDAE.Var v;
      BackendVarTransform.VariableReplacements repl,repl_1;
      DAE.ComponentRef varName;
      Option< .DAE.VariableAttributes> values;
      DAE.Exp exp;
      Values.Value bindValue;
    case (v as BackendDAE.VAR(varName=varName,varKind=BackendDAE.PARAM(),bindExp=SOME(exp),values=values),repl)
      equation
        true = DAEUtil.getProtectedAttr(values);
        repl_1 = BackendVarTransform.addReplacement(repl, varName, exp,NONE());
      then (v,repl_1);
    case (v as BackendDAE.VAR(varName=varName,varKind=BackendDAE.PARAM(),bindValue=SOME(bindValue),values=values),repl)
      equation
        true = DAEUtil.getProtectedAttr(values);
        true = BackendVariable.varFixed(v);
        exp = ValuesUtil.valueExp(bindValue);
        repl_1 = BackendVarTransform.addReplacement(repl, varName, exp,NONE());
      then (v,repl_1);
    else (inVar,inRepl);
  end matchcontinue;
end protectedParametersFinder;


// =============================================================================
// remove equal function calls equations stuff
//
// =============================================================================
public function removeEqualFunctionCalls "author: Frenkel TUD 2011-04
  This function detects equal function calls of the form a=f(b) and c=f(b) in
  BackendDAE.BackendDAE to get speed up."
  input BackendDAE.BackendDAE dae;
  output BackendDAE.BackendDAE odae;
algorithm
  odae := BackendDAEUtil.mapEqSystem(dae,removeEqualFunctionCallsWork);
end removeEqualFunctionCalls;

protected function removeEqualFunctionCallsWork "author: Frenkel TUD 2011-04
  This function detects equal function calls of the form a=f(b) and c=f(b) in
  BackendDAE.BackendDAE to get speed up."
  input BackendDAE.EqSystem isyst;
  input BackendDAE.Shared ishared;
  output BackendDAE.EqSystem osyst;
  output BackendDAE.Shared oshared;
algorithm
  (osyst,oshared) := match (isyst,ishared)
    local
      BackendDAE.IncidenceMatrix m,m_1;
      BackendDAE.IncidenceMatrixT mT,mT_1;
      BackendDAE.Variables vars;
      BackendDAE.EquationArray eqns,eqns1;
      list<Integer> changed;
      Boolean b;
      BackendDAE.EqSystem syst;
      BackendDAE.Shared shared;
      BackendDAE.StateSets stateSets;
      DAE.FunctionTree funcs;
      BackendDAE.BaseClockPartitionKind partitionKind;

    case (syst as BackendDAE.EQSYSTEM(orderedVars=vars,orderedEqs=eqns,stateSets=stateSets,partitionKind=partitionKind),shared)
      equation
        funcs = BackendDAEUtil.getFunctions(shared);
        (syst,m,mT) = BackendDAEUtil.getIncidenceMatrixfromOption(syst,BackendDAE.NORMAL(),SOME(funcs));
        // check equations
        (m_1,(mT_1,_,_,changed)) = traverseIncidenceMatrix(m,removeEqualFunctionCallFinder,(mT,vars,eqns,{}));
        _ = List.isNotEmpty(changed);
        // update arrayeqns and algorithms, collect info for wrappers
        syst = BackendDAE.EQSYSTEM(vars,eqns,SOME(m_1),SOME(mT_1),BackendDAE.NO_MATCHING(),stateSets,partitionKind);
        syst = BackendDAEUtil.updateIncidenceMatrix(syst,BackendDAE.NORMAL(),NONE(),changed);
      then (syst,shared);
  end match;
end removeEqualFunctionCallsWork;

protected function removeEqualFunctionCallFinder "author: Frenkel TUD 2010-12"
 input tuple<BackendDAE.IncidenceMatrixElement,Integer,BackendDAE.IncidenceMatrix, tuple<BackendDAE.IncidenceMatrixT,BackendDAE.Variables,BackendDAE.EquationArray,list<Integer>>> inTpl;
 output tuple<list<Integer>,BackendDAE.IncidenceMatrix, tuple<BackendDAE.IncidenceMatrixT,BackendDAE.Variables,BackendDAE.EquationArray,list<Integer>>> outTpl;
algorithm
  outTpl:=
  matchcontinue (inTpl)
    local
      BackendDAE.IncidenceMatrixElement elem;
      Integer pos;
      BackendDAE.IncidenceMatrix m,mT;
      list<Integer> changed;
      BackendDAE.Variables vars;
      BackendDAE.EquationArray eqns,eqns1;
      DAE.Exp exp,e1,e2,ecr;
      list<Integer> expvars,controleqns,expvars1;
      list<list<Integer>> expvarseqns;

    case ((elem,pos,m,(mT,vars,eqns,changed)))
      equation
        // check number of vars in eqns
        _::_ = elem;
        BackendDAE.EQUATION(exp=e1,scalar=e2) = BackendEquation.equationNth1(eqns,pos);
        // BackendDump.debugStrExpStrExpStr(("Test ",e1," = ",e2,"\n"));
        (ecr,exp) = functionCallEqn(e1,e2,vars);
        // TODO: Handle this with alias-equations instead?; at least they don't replace back to the original expression...
        // failure(DAE.CREF(componentRef=_) = exp);
        // failure(DAE.UNARY(operator=DAE.UMINUS(ty=_),exp=DAE.CREF(componentRef=_)) = exp);
        // BackendDump.debugStrExpStrExpStr(("Found ",ecr," = ",exp,"\n"));
        expvars = BackendDAEUtil.incidenceRowExp(exp,vars,{},NONE(),BackendDAE.NORMAL());
        // print("expvars "); BackendDump.debuglst((expvars,intString," ","\n"));
        (expvars1::expvarseqns) = List.map1(expvars,varEqns,(pos,mT));
        // print("expvars1 "); BackendDump.debuglst((expvars1,intString," ","\n"));;
        controleqns = getControlEqns(expvars1,expvarseqns);
        // print("controleqns "); BackendDump.debuglst((controleqns,intString," ","\n"));
        (eqns1,changed) = removeEqualFunctionCall(controleqns,ecr,exp,eqns,changed);
        //print("changed1 "); BackendDump.debuglst((changed1,intString," ","\n"));
        //print("changed2 "); BackendDump.debuglst((changed2,intString," ","\n"));
        // print("Next\n");
      then (({},m,(mT,vars,eqns1,changed)));
    case ((_,_,m,(mT,vars,eqns,changed)))
      then (({},m,(mT,vars,eqns,changed)));
  end matchcontinue;
end removeEqualFunctionCallFinder;

protected function functionCallEqn
"author Frenkel TUD 2011-04"
  input DAE.Exp ie1;
  input DAE.Exp ie2;
  input BackendDAE.Variables inVars;
  output DAE.Exp outECr;
  output DAE.Exp outExp;
algorithm
  (outECr,outExp) := match (ie1,ie2,inVars)
      local
        DAE.ComponentRef cr;
        DAE.Exp e1,e2;
        DAE.Operator op;

      case (DAE.CREF(),DAE.UNARY(operator=DAE.UMINUS(),exp=DAE.CREF()),_)
        then fail();
      case (DAE.CREF(),DAE.CREF(),_)
        then fail();
      case (DAE.UNARY(operator=DAE.UMINUS(),exp=DAE.CREF()),DAE.CREF(),_)
        then fail();
      // a = -f(...);
      case (e1 as DAE.CREF(componentRef = cr),DAE.UNARY(operator=op as DAE.UMINUS(),exp=e2),_)
        equation
          ((_::_),(_::_)) = BackendVariable.getVar(cr,inVars);
        then (DAE.UNARY(op,e1),e2);
      // a = f(...);
      case (e1 as DAE.CREF(componentRef = cr),e2,_)
        equation
          ((_::_),(_::_)) = BackendVariable.getVar(cr,inVars);
        then (e1,e2);
      // a = -f(...);
      case (DAE.UNARY(operator=op as DAE.UMINUS(),exp=e1),e2 as DAE.CREF(componentRef = cr),_)
        equation
          ((_::_),(_::_)) = BackendVariable.getVar(cr,inVars);
        then (DAE.UNARY(op,e2),e1);
      // f(...)=a;
      case (e1,e2 as DAE.CREF(componentRef = cr),_)
        equation
          ((_::_),(_::_)) = BackendVariable.getVar(cr,inVars);
        then (e2,e1);
  end match;
end functionCallEqn;

protected function varEqns
"author Frenkel TUD 2011-04"
  input Integer v;
  input tuple<Integer,BackendDAE.IncidenceMatrixT> inTpl;
  output list<Integer> outVarEqns;
protected
  Integer pos;
  list<Integer> vareqns,vareqns1;
  BackendDAE.IncidenceMatrix mT;
algorithm
  pos := Util.tuple21(inTpl);
  mT := Util.tuple22(inTpl);
  vareqns := mT[intAbs(v)];
  vareqns1 := List.map(vareqns, intAbs);
  outVarEqns := List.removeOnTrue(intAbs(pos),intEq,vareqns1);
end varEqns;

protected function getControlEqns
"author Frenkel TUD 2011-04"
  input list<Integer> inVarsEqn;
  input list<list<Integer>> inVarsEqns;
  output list<Integer> outEqns;
algorithm
  outEqns := match(inVarsEqn,inVarsEqns)
    local
      list<Integer> a,b,c,d;
      list<list<Integer>> rest;
    case (a,{}) then a;
    case (a,b::rest)
      equation
       c = List.intersectionOnTrue(a,b,intEq);
       d = getControlEqns(c,rest);
      then d;
  end match;
end getControlEqns;

protected function removeEqualFunctionCall
"author: Frenkel TUD 2011-04"
  input list<Integer> inEqsLst;
  input DAE.Exp inExp;
  input DAE.Exp inECr;
  input BackendDAE.EquationArray inEqns;
  input list<Integer> ichanged;
  output BackendDAE.EquationArray outEqns;
  output list<Integer> outEqsLst;
algorithm
  (outEqns,outEqsLst):=
  matchcontinue (inEqsLst,inExp,inECr,inEqns,ichanged)
    local
      BackendDAE.EquationArray eqns;
      BackendDAE.Equation eqn,eqn1;
      Integer pos,i;
      list<Integer> rest,changed;
    case ({},_,_,_,_) then (inEqns,ichanged);
    case (pos::rest,_,_,_,_)
      equation
        eqn = BackendEquation.equationNth1(inEqns,pos);
        //BackendDump.printEquationList({eqn});
        //BackendDump.debugStrExpStrExpStr(("Repalce ",inExp," with ",inECr,"\n"));
        (eqn1,(_,_,i)) = BackendDAETransform.traverseBackendDAEExpsEqnWithSymbolicOperation(eqn, replaceExp, (inECr,inExp,0));
        //BackendDump.printEquationList({eqn1});
        //print("i="); print(intString(i)); print("\n");
        true = intGt(i,0);
        eqns =  BackendEquation.setAtIndex(inEqns,pos,eqn1);
        changed = List.consOnTrue(not listMember(pos,ichanged),pos,ichanged);
        (eqns,changed) = removeEqualFunctionCall(rest,inExp,inECr,eqns,changed);
      then (eqns,changed);
    case (_::rest,_,_,_,_)
      equation
        (eqns,changed) = removeEqualFunctionCall(rest,inExp,inECr,inEqns,ichanged);
      then (eqns,changed);
  end matchcontinue;
end removeEqualFunctionCall;

protected function replaceExp
  input DAE.Exp inExp;
  input tuple<list<DAE.SymbolicOperation>, tuple<DAE.Exp, DAE.Exp, Integer>> inTpl;
  output DAE.Exp e1;
  output tuple<list<DAE.SymbolicOperation>, tuple<DAE.Exp, DAE.Exp, Integer>> outTpl;
protected
  DAE.Exp e, se, te;
  Integer i, j;
  list<DAE.SymbolicOperation> ops;
algorithm
  e := inExp;
  (ops, (se, te, i)) := inTpl;
  // BackendDump.debugStrExpStrExpStr(("Repalce ", se, " with ", te, "\n"));
  ((e1, j)) := Expression.replaceExp(e, se, te);
  ops := if j>0 then DAE.SUBSTITUTION({e1}, e)::ops else ops;
  // BackendDump.debugStrExpStrExpStr(("Old ", e, " new ", e1, "\n"));
  outTpl := (ops, (se, te, i+j));
end replaceExp;

// =============================================================================
// remove unused parameter
//
// =============================================================================
public function removeUnusedParameter
"author: Frenkel TUD 2011-04
  This function remove unused parameters
  in BackendDAE.BackendDAE to get speed up for compilation of
  target code"
  input BackendDAE.BackendDAE inDlow;
  output BackendDAE.BackendDAE outDlow;
algorithm
  outDlow := match (inDlow)
    local
      BackendDAE.Variables knvars,exobj,knvars1,aliasVars;
      BackendDAE.EquationArray remeqns,inieqns;
      list<DAE.Constraint> constrs;
      list<DAE.ClassAttributes> clsAttrs;
      FCore.Cache cache;
      FCore.Graph graph;
      DAE.FunctionTree funcs;
      BackendDAE.EventInfo einfo;
      BackendDAE.SymbolicJacobians symjacs;
      list<BackendDAE.WhenClause> whenClauseLst;
      BackendDAE.ExternalObjectClasses eoc;
      BackendDAE.EqSystems eqs;
      BackendDAE.BackendDAEType btp;
      BackendDAE.ExtraInfo ei;

    case (BackendDAE.DAE(eqs,BackendDAE.SHARED(knvars,exobj,aliasVars,inieqns,remeqns,constrs,clsAttrs,cache,graph,funcs,einfo as BackendDAE.EVENT_INFO(whenClauseLst=whenClauseLst),eoc,btp,symjacs,ei)))
      equation
        knvars1 = BackendVariable.emptyVars();
        ((knvars,knvars1)) = BackendVariable.traverseBackendDAEVars(knvars,copyNonParamVariables,(knvars,knvars1));
        ((_,knvars1)) = List.fold1(eqs,BackendDAEUtil.traverseBackendDAEExpsEqSystem,checkUnusedVariables,(knvars,knvars1));
        ((_,knvars1)) = BackendDAEUtil.traverseBackendDAEExpsVars(knvars,checkUnusedParameter,(knvars,knvars1));
        ((_,knvars1)) = BackendDAEUtil.traverseBackendDAEExpsVars(aliasVars,checkUnusedParameter,(knvars,knvars1));
        ((_,knvars1)) = BackendDAEUtil.traverseBackendDAEExpsEqns(remeqns,checkUnusedParameter,(knvars,knvars1));
        ((_,knvars1)) = BackendDAEUtil.traverseBackendDAEExpsEqns(inieqns,checkUnusedParameter,(knvars,knvars1));
        (_,(_,knvars1)) = BackendDAETransform.traverseBackendDAEExpsWhenClauseLst(whenClauseLst,checkUnusedParameter,(knvars,knvars1));
      then
        BackendDAE.DAE(eqs,BackendDAE.SHARED(knvars1,exobj,aliasVars,inieqns,remeqns,constrs,clsAttrs,cache,graph,funcs,einfo,eoc,btp,symjacs,ei));
  end match;
end removeUnusedParameter;

protected function copyNonParamVariables
  input BackendDAE.Var inVar;
  input tuple<BackendDAE.Variables,BackendDAE.Variables> inTpl;
  output BackendDAE.Var outVar;
  output tuple<BackendDAE.Variables,BackendDAE.Variables> outTpl;
algorithm
  (outVar,outTpl) := matchcontinue (inVar,inTpl)
    local
      BackendDAE.Var v;
      BackendDAE.Variables vars,vars1;
      DAE.ComponentRef cr;
    case (v as BackendDAE.VAR(varKind = BackendDAE.PARAM()),(vars,vars1))
      then (v,(vars,vars1));
    case (v as BackendDAE.VAR(),(vars,vars1))
      equation
        vars1 = BackendVariable.addVar(v,vars1);
      then (v,(vars,vars1));
  end matchcontinue;
end copyNonParamVariables;

protected function checkUnusedParameter
  input DAE.Exp inExp;
  input tuple<BackendDAE.Variables,BackendDAE.Variables> inTpl;
  output DAE.Exp outExp;
  output tuple<BackendDAE.Variables,BackendDAE.Variables> outTpl;
algorithm
  (outExp,outTpl) := matchcontinue (inExp,inTpl)
    local
      DAE.Exp exp;
      BackendDAE.Variables vars,vars1;
    case (exp,(vars,vars1))
      equation
         (_,(_,vars1)) = Expression.traverseExp(exp,checkUnusedParameterExp,(vars,vars1));
       then (exp,(vars,vars1));
    else (inExp,inTpl);
  end matchcontinue;
end checkUnusedParameter;

protected function checkUnusedParameterExp
  input DAE.Exp inExp;
  input tuple<BackendDAE.Variables,BackendDAE.Variables> inTuple;
  output DAE.Exp outExp;
  output tuple<BackendDAE.Variables,BackendDAE.Variables> outTuple;
algorithm
  (outExp,outTuple) := matchcontinue (inExp,inTuple)
    local
      DAE.Exp e,e1;
      BackendDAE.Variables vars,vars1;
      DAE.ComponentRef cr;
      list<DAE.Exp> expl;
      list<DAE.Var> varLst;
      BackendDAE.Var var;

    // special case for time, it is never part of the equation system
    case (e as DAE.CREF(componentRef = DAE.CREF_IDENT(ident="time")),(vars,vars1))
      then (e, (vars,vars1));

    // Special Case for Records
    case (e as DAE.CREF(componentRef = cr,ty= DAE.T_COMPLEX(varLst=varLst,complexClassType=ClassInf.RECORD(_))),(vars,vars1))
      equation
        expl = List.map1(varLst,Expression.generateCrefsExpFromExpVar,cr);
        (_,(vars,vars1)) = Expression.traverseExpList(expl,checkUnusedParameterExp,(vars,vars1));
      then (e, (vars,vars1));

    // Special Case for Arrays
    case (e as DAE.CREF(ty = DAE.T_ARRAY()),(vars,vars1))
      equation
        (e1,true) = Expression.extendArrExp(e,false);
        (_,(vars,vars1)) = Expression.traverseExp(e1,checkUnusedParameterExp,(vars,vars1));
      then (e, (vars,vars1));

    // case for functionpointers
    case (e as DAE.CREF(ty=DAE.T_FUNCTION_REFERENCE_FUNC()),_)
      then (e, inTuple);

    // already there
    case (e as DAE.CREF(componentRef = cr),(_,vars1))
      equation
        (_,_) = BackendVariable.getVar(cr, vars1);
      then (e, inTuple);

    // add it
    case (e as DAE.CREF(componentRef = cr),(vars,vars1))
      equation
         (var::_,_) = BackendVariable.getVar(cr, vars);
         vars1 = BackendVariable.addVar(var,vars1);
      then (e, (vars,vars1));

    else (inExp,inTuple);
  end matchcontinue;
end checkUnusedParameterExp;

// =============================================================================
// remove unused variables
//
// =============================================================================
public function removeUnusedVariables
"author: Frenkel TUD 2011-04
  This function remove unused variables
  from BackendDAE.BackendDAE to get speed up for compilation of
  target code"
  input BackendDAE.BackendDAE inDlow;
  output BackendDAE.BackendDAE outDlow;
algorithm
  outDlow := match (inDlow)
    local
      FCore.Cache cache;
      FCore.Graph graph;
      DAE.FunctionTree funcs;
      BackendDAE.Variables knvars,exobj,knvars1,aliasVars;
      BackendDAE.EquationArray remeqns,inieqns;
      list<DAE.Constraint> constrs;
      list<DAE.ClassAttributes> clsAttrs;
      BackendDAE.EventInfo einfo;
      list<BackendDAE.WhenClause> whenClauseLst;
      BackendDAE.ExternalObjectClasses eoc;
      BackendDAE.SymbolicJacobians symjacs;
      BackendDAE.EqSystems eqs;
      BackendDAE.BackendDAEType btp;
      BackendDAE.ExtraInfo ei;

    case (BackendDAE.DAE(eqs,BackendDAE.SHARED(knvars,exobj,aliasVars,inieqns,remeqns,constrs,clsAttrs,cache,graph,funcs,einfo as BackendDAE.EVENT_INFO(whenClauseLst=whenClauseLst),eoc,btp,symjacs,ei)))
      equation
        knvars1 = BackendVariable.emptyVars();
        ((_,knvars1)) = List.fold1(eqs,BackendDAEUtil.traverseBackendDAEExpsEqSystem,checkUnusedVariables,(knvars,knvars1));
        ((_,knvars1)) = BackendDAEUtil.traverseBackendDAEExpsVars(knvars,checkUnusedVariables,(knvars,knvars1));
        ((_,knvars1)) = BackendDAEUtil.traverseBackendDAEExpsVars(aliasVars,checkUnusedVariables,(knvars,knvars1));
        ((_,knvars1)) = BackendDAEUtil.traverseBackendDAEExpsEqns(remeqns,checkUnusedVariables,(knvars,knvars1));
        ((_,knvars1)) = BackendDAEUtil.traverseBackendDAEExpsEqns(inieqns,checkUnusedVariables,(knvars,knvars1));
        (_,(_,knvars1)) = BackendDAETransform.traverseBackendDAEExpsWhenClauseLst(whenClauseLst,checkUnusedVariables,(knvars,knvars1));
      then
        BackendDAE.DAE(eqs,BackendDAE.SHARED(knvars1,exobj,aliasVars,inieqns,remeqns,constrs,clsAttrs,cache,graph,funcs,einfo,eoc,btp,symjacs,ei));
  end match;
end removeUnusedVariables;

protected function checkUnusedVariables
  input DAE.Exp inExp;
  input tuple<BackendDAE.Variables,BackendDAE.Variables> inTpl;
  output DAE.Exp outExp;
  output tuple<BackendDAE.Variables,BackendDAE.Variables> outTpl;
algorithm
  (outExp,outTpl) := matchcontinue (inExp,inTpl)
    local
      DAE.Exp exp;
      BackendDAE.Variables vars,vars1;
    case (exp,(vars,vars1))
      equation
         (_,(_,vars1)) = Expression.traverseExp(exp,checkUnusedVariablesExp,(vars,vars1));
       then (exp,(vars,vars1));
    else (inExp,inTpl);
  end matchcontinue;
end checkUnusedVariables;

protected function checkUnusedVariablesExp
  input DAE.Exp inExp;
  input tuple<BackendDAE.Variables,BackendDAE.Variables> inTuple;
  output DAE.Exp outExp;
  output tuple<BackendDAE.Variables,BackendDAE.Variables> outTuple;
algorithm
  (outExp,outTuple) := matchcontinue (inExp,inTuple)
    local
      DAE.Exp e,e1;
      BackendDAE.Variables vars,vars1;
      DAE.ComponentRef cr;
      list<DAE.Exp> expl;
      list<DAE.Var> varLst;
      BackendDAE.Var var;

    // special case for time, it is never part of the equation system
    case (e as DAE.CREF(componentRef = DAE.CREF_IDENT(ident="time")),(vars,vars1))
      then (e, (vars,vars1));

    // Special Case for Records
    case (e as DAE.CREF(componentRef = cr,ty= DAE.T_COMPLEX(varLst=varLst,complexClassType=ClassInf.RECORD(_))),(vars,vars1))
      equation
        expl = List.map1(varLst,Expression.generateCrefsExpFromExpVar,cr);
        (_,(vars,vars1)) = Expression.traverseExpList(expl,checkUnusedVariablesExp,(vars,vars1));
      then (e, (vars,vars1));

    // Special Case for Arrays
    case (e as DAE.CREF(ty = DAE.T_ARRAY()),(vars,vars1))
      equation
        (e1,true) = Expression.extendArrExp(e,false);
        (_,(vars,vars1)) = Expression.traverseExp(e1,checkUnusedVariablesExp,(vars,vars1));
      then (e, (vars,vars1));

    // case for functionpointers
    case (DAE.CREF(ty=DAE.T_FUNCTION_REFERENCE_FUNC()),_)
      then (inExp, inTuple);

    // already there
    case (DAE.CREF(componentRef = cr),(_,vars1))
      equation
         (_,_) = BackendVariable.getVar(cr, vars1);
      then (inExp, inTuple);

    // add it
    case (DAE.CREF(componentRef = cr),(vars,vars1))
      equation
         (var::_,_) = BackendVariable.getVar(cr, vars);
         vars1 = BackendVariable.addVar(var,vars1);
      then (inExp, (vars,vars1));

    else (inExp,inTuple);
  end matchcontinue;
end checkUnusedVariablesExp;

// =============================================================================
// remove unused functions
//
// =============================================================================
public function removeUnusedFunctions "author: Frenkel TUD 2012-03
  This function remove unused functions from DAE.FunctionTree to get speed up
  for compilation of target code."
  input BackendDAE.BackendDAE inDlow;
  output BackendDAE.BackendDAE outDlow;
protected
  FCore.Cache cache;
  FCore.Graph graph;
  DAE.FunctionTree funcs,usedfuncs;
  BackendDAE.Variables knvars,exobj,aliasVars;
  BackendDAE.EquationArray remeqns,inieqns;
  list<DAE.Constraint> constrs;
  list<DAE.ClassAttributes> clsAttrs;
  BackendDAE.EventInfo einfo;
  list<BackendDAE.WhenClause> whenClauseLst;
  BackendDAE.ExternalObjectClasses eoc;
  BackendDAE.SymbolicJacobians symjacs;
  BackendDAE.EqSystems eqs;
  BackendDAE.BackendDAEType btp;
  BackendDAE.ExtraInfo ei;
  BackendDAE.Shared shared;

  partial function FuncType
    input DAE.Exp inExp;
    input tuple<DAE.FunctionTree, DAE.FunctionTree> inTuple;
    output DAE.Exp outExp;
    output tuple<DAE.FunctionTree, DAE.FunctionTree> outTuple;
  end FuncType;

  FuncType func;
algorithm
  BackendDAE.DAE(eqs, shared) := inDlow;
  BackendDAE.SHARED(knvars, exobj, aliasVars, inieqns, remeqns, constrs,
      clsAttrs, cache, graph, funcs, einfo, eoc, btp, symjacs, ei) := shared;
  BackendDAE.EVENT_INFO(whenClauseLst = whenClauseLst) := einfo;

  usedfuncs := copyRecordConstructorAndExternalObjConstructorDestructor(funcs);

  func := checkUnusedFunctionsTupleWrapper;
  (_, usedfuncs) := List.fold1(eqs, BackendDAEUtil.traverseBackendDAEExpsEqSystem, func, (funcs, usedfuncs));
  (_, usedfuncs) := List.fold1(eqs, BackendDAEUtil.traverseBackendDAEExpsEqSystemJacobians, func, (funcs, usedfuncs));
  (_, usedfuncs) := BackendDAEUtil.traverseBackendDAEExpsVars(knvars, func, (funcs, usedfuncs));
  (_, usedfuncs) := BackendDAEUtil.traverseBackendDAEExpsVars(exobj, func, (funcs, usedfuncs));
  (_, usedfuncs) := BackendDAEUtil.traverseBackendDAEExpsVars(aliasVars, func, (funcs, usedfuncs));
  (_, usedfuncs) := BackendDAEUtil.traverseBackendDAEExpsEqns(remeqns, func, (funcs, usedfuncs));
  (_, usedfuncs) := BackendDAEUtil.traverseBackendDAEExpsEqns(inieqns, func, (funcs, usedfuncs));
  (_, (_, usedfuncs)) := BackendDAETransform.traverseBackendDAEExpsWhenClauseLst(whenClauseLst, func, (funcs, usedfuncs));

  //traverse Symbolic jacobians
  usedfuncs := removeUnusedFunctionsSymJacs(symjacs, funcs, usedfuncs);

  shared := BackendDAE.SHARED(knvars, exobj, aliasVars, inieqns, remeqns,
    constrs, clsAttrs, cache, graph, usedfuncs, einfo, eoc, btp, symjacs, ei);
  outDlow := BackendDAE.DAE(eqs, shared);
end removeUnusedFunctions;

protected function copyRecordConstructorAndExternalObjConstructorDestructor
  input DAE.FunctionTree inFunctions;
  output DAE.FunctionTree outFunctions;
protected
  list<DAE.Function> funcelems;
algorithm
  funcelems := DAEUtil.getFunctionList(inFunctions);
  outFunctions := List.fold(funcelems,copyRecordConstructorAndExternalObjConstructorDestructorFold,DAE.emptyFuncTree);
end copyRecordConstructorAndExternalObjConstructorDestructor;

protected function copyRecordConstructorAndExternalObjConstructorDestructorFold
  input DAE.Function inFunction;
  input DAE.FunctionTree inFunctions;
  output DAE.FunctionTree outFunctions;
algorithm
  outFunctions :=
  matchcontinue (inFunction,inFunctions)
    local
      DAE.Function f;
      DAE.FunctionTree funcs,funcs1;
      Absyn.Path path;
    // copy record constructors
    case (f as DAE.RECORD_CONSTRUCTOR(path=path),funcs)
      equation
         funcs1 = DAEUtil.avlTreeAdd(funcs, path, SOME(f));
       then
        funcs1;
    // copy external objects constructors/destructors
    case (f as DAE.FUNCTION(path = path),funcs)
      equation
         true = boolOr(
                  stringEq(Absyn.pathLastIdent(path), "constructor"),
                  stringEq(Absyn.pathLastIdent(path), "destructor"));
         funcs1 = DAEUtil.avlTreeAdd(funcs, path, SOME(f));
       then
        funcs1;
    case (_,funcs) then funcs;
  end matchcontinue;
end copyRecordConstructorAndExternalObjConstructorDestructorFold;

protected function removeUnusedFunctionsSymJacs
  input BackendDAE.SymbolicJacobians inSymJacs;
  input DAE.FunctionTree inFunctions;
  input DAE.FunctionTree inUsedFunctions;
  output DAE.FunctionTree outUsedFunctions := inUsedFunctions;
algorithm
  for sjac in inSymJacs loop
    _ := match(sjac)
      local
        BackendDAE.BackendDAE bdae;
        DAE.FunctionTree usedfuncs;

      case (SOME((bdae, _, _, _, _)), _, _)
        equation
          bdae = BackendDAEUtil.addBackendDAEFunctionTree(inFunctions, bdae);
          BackendDAE.DAE(shared = BackendDAE.SHARED(functionTree = usedfuncs)) =
            removeUnusedFunctions(bdae);
          outUsedFunctions = DAEUtil.joinAvlTrees(outUsedFunctions, usedfuncs);
        then
          ();

      else ();
    end match;
  end for;
end removeUnusedFunctionsSymJacs;

protected function checkUnusedFunctionsTupleWrapper
  input DAE.Exp inExp;
  input tuple<DAE.FunctionTree, DAE.FunctionTree> inTuple;
  output DAE.Exp outExp;
  output tuple<DAE.FunctionTree, DAE.FunctionTree> outTuple;
protected
  DAE.FunctionTree funcs, used_funcs;
algorithm
  (funcs, used_funcs) := inTuple;
  (outExp, used_funcs) := checkUnusedFunctions(inExp, funcs, used_funcs);
  outTuple := (funcs, used_funcs);
end checkUnusedFunctionsTupleWrapper;

protected function checkUnusedFunctions
  input DAE.Exp inExp;
  input DAE.FunctionTree inFunctions;
  input DAE.FunctionTree inUsedFunctions;
  output DAE.Exp outExp;
  output DAE.FunctionTree outUsedFunctions;
algorithm
  (outExp, (_, outUsedFunctions)) := Expression.traverseExp(inExp,
      checkUnusedFunctionsExpTupleWrapper, (inFunctions, inUsedFunctions));
end checkUnusedFunctions;

protected function checkUnusedFunctionsExpTupleWrapper
  input DAE.Exp inExp;
  input tuple<DAE.FunctionTree, DAE.FunctionTree> inTuple;
  output DAE.Exp outExp;
  output tuple<DAE.FunctionTree, DAE.FunctionTree> outTuple;
protected
  DAE.FunctionTree funcs, used_funcs;
algorithm
  (funcs, used_funcs) := inTuple;
  (outExp, used_funcs) := checkUnusedFunctionsExp(inExp, funcs, used_funcs);
  outTuple := (funcs, used_funcs);
end checkUnusedFunctionsExpTupleWrapper;

protected function checkUnusedFunctionsExp
  input DAE.Exp inExp;
  input DAE.FunctionTree inFunctions;
  input DAE.FunctionTree inUsedFunctions;
  output DAE.Exp outExp := inExp;
  output DAE.FunctionTree outUsedFunctions;
algorithm
  outUsedFunctions := match(inExp)
    local
      Absyn.Path path;
      DAE.ComponentRef cr;
      DAE.FunctionTree usedfuncs;

    // If the expression is some kind of function call, add it to the used functions.
    case DAE.CALL(path = path)
      then addUnusedFunction(path, inFunctions, inUsedFunctions);

    case DAE.PARTEVALFUNCTION(path = path)
      then addUnusedFunction(path, inFunctions, inUsedFunctions);

    case DAE.CREF(ty = DAE.T_FUNCTION_REFERENCE_FUNC(functionType =
        DAE.T_FUNCTION(source = {path})))
      then addUnusedFunction(path, inFunctions, inUsedFunctions);

    // If it's a cref, check the cref's dimensions for function calls.
    case DAE.CREF(componentRef = cr)
      algorithm
        (_, (_, usedfuncs)) := Expression.traverseExpCrefDims(cr,
          checkUnusedFunctionsTupleWrapper, (inFunctions, inUsedFunctions));
      then
        usedfuncs;

    // Otherwise, do nothing.
    else inUsedFunctions;
  end match;
end checkUnusedFunctionsExp;

protected function addUnusedFunction
  input Absyn.Path inPath;
  input DAE.FunctionTree inFunctions;
  input DAE.FunctionTree inUsedFunctions;
  output DAE.FunctionTree outUsedFunctions := inUsedFunctions;
protected
  Option<DAE.Function> f;
  list<DAE.Element> body;
algorithm
  try // Check if the function has already been added.
    _ := DAEUtil.avlTreeGet(inUsedFunctions, inPath);
  else // Otherwise, try to add it.
    (f, body) := getFunctionAndBody(inPath, inFunctions);
    if isNone(f) then return; end if; // Return if the function couldn't be found.
    outUsedFunctions := DAEUtil.avlTreeAdd(outUsedFunctions, inPath, f);
    (_, (_, outUsedFunctions)) := DAEUtil.traverseDAE2(body,
      checkUnusedFunctionsTupleWrapper, (inFunctions, outUsedFunctions));
  end try;
end addUnusedFunction;

protected function getFunctionAndBody
"returns the body of a function"
  input Absyn.Path inPath;
  input DAE.FunctionTree fns;
  output Option<DAE.Function> outFn;
  output list<DAE.Element> outFnBody;
protected
  DAE.Function fn;
algorithm
  try
    outFn as SOME(fn) := DAEUtil.avlTreeGet(fns, inPath);
    outFnBody := DAEUtil.getFunctionElements(fn);
  else
    outFn := NONE();
    outFnBody := {};
  end try;
end getFunctionAndBody;

// =============================================================================
// initialization stuff
//
// =============================================================================
public function collectInitialEquations "author: lochel
  This function collects all initial equations in the following order:
    - initial equations
    - implicit initial equations
    - parameter binding with fixed=false
    - initial algorithms"
  input BackendDAE.BackendDAE inDAE;
  output list<BackendDAE.Equation> outEquations;
  output Integer outNumberOfInitialEquations;
  output Integer outNumberOfInitialAlgorithms;
algorithm
  (outEquations, outNumberOfInitialEquations, outNumberOfInitialAlgorithms) := matchcontinue(inDAE)
    local
      BackendDAE.EqSystems eqs;
      BackendDAE.EquationArray initialEqs;
      BackendDAE.Shared shared;

      Integer numberOfInitialEquations, numberOfInitialAlgorithms;
      list<BackendDAE.Equation> initialEqs_lst, initialEqs_lst1, initialEqs_lst2, initialEqs_lst3;

    case (BackendDAE.DAE(eqs=eqs, shared=(shared as BackendDAE.SHARED(initialEqs=initialEqs)))) equation
      // [initial equations]
      // initial_equation
      initialEqs_lst = BackendEquation.equationList(initialEqs);
      // [initial algorithms]
      // remove algorithms, I have no clue what the reason is but is was done before also
      // but they are moved to the end
      (initialEqs_lst1,initialEqs_lst3) = List.splitOnTrue(initialEqs_lst, BackendEquation.isNotAlgorithm);

      // [orderedVars] with fixed=true
      // 0 = v - start(v); fixed(v) = true
      initialEqs_lst2 = List.fold(eqs,generateImplicitInitialEquationsSystem,initialEqs_lst3);
      // [knownVars] with fixed=false
      // 0 = p - p.binding; fixed(p) = false
      initialEqs_lst2 = generateImplicitInitialEquationsSystemForParameters(shared, initialEqs_lst2);

      // append and count
      initialEqs_lst = listAppend(initialEqs_lst1, initialEqs_lst2);
      numberOfInitialEquations = BackendEquation.equationLstSize(initialEqs_lst);
      numberOfInitialAlgorithms = BackendEquation.equationLstSize(initialEqs_lst3);
      numberOfInitialEquations = numberOfInitialEquations-numberOfInitialAlgorithms;
    then (initialEqs_lst, numberOfInitialEquations, numberOfInitialAlgorithms);

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"./Compiler/BackEnd/BackendDAEOptimize.mo: function collectInitialEquations failed"});
    then fail();
  end matchcontinue;
end collectInitialEquations;



protected function generateImplicitInitialEquationsSystem "author: Frenkel TUD
  Helper for collectInitialEquations.
  This function generates implicit initial equations for fixed variables."
  input BackendDAE.EqSystem system;
  input list<BackendDAE.Equation> inEqns;
  output list<BackendDAE.Equation> outEqns;
protected
  BackendDAE.Variables vars;
algorithm
  vars := BackendVariable.daeVars(system);
  outEqns := BackendVariable.traverseBackendDAEVars(vars, generateImplicitInitialEquations, inEqns);
end generateImplicitInitialEquationsSystem;

protected function generateImplicitInitialEquationsSystemForParameters "author: lochel
  Helper for collectInitialEquations.
  This function generates implicit initial equations for unfixed parameters."
  input BackendDAE.Shared shared;
  input list<BackendDAE.Equation> inEqns;
  output list<BackendDAE.Equation> outEqns;
protected
  BackendDAE.Variables vars;
algorithm
  vars := BackendVariable.daeKnVars(shared);
  outEqns := BackendVariable.traverseBackendDAEVars(vars, generateImplicitInitialEquationsForParameters, inEqns);
end generateImplicitInitialEquationsSystemForParameters;

protected function generateImplicitInitialEquations "author: lochel
  Helper for collectInitialEquations.
  This function generates implicit initial equations for fixed variables."
  input BackendDAE.Var inVar;
  input list<BackendDAE.Equation> inEqs;
  output BackendDAE.Var outVar;
  output list<BackendDAE.Equation> outEqs;
algorithm
  (outVar,outEqs) := matchcontinue (inVar,inEqs)
    local
      BackendDAE.Var var;
      BackendDAE.Equation eqn;
      list<BackendDAE.Equation> eqns;
      DAE.Exp e, e1, crefExp, startExp;
      DAE.ComponentRef cref;
      DAE.Type tp;

    case (var,eqns) equation
      true = BackendVariable.varFixed(var);
      false = BackendVariable.isStateVar(var);
      false = BackendVariable.isParam(var);
      false = BackendVariable.isVarDiscrete(var);

      cref = BackendVariable.varCref(var);
      crefExp = DAE.CREF(cref, DAE.T_REAL_DEFAULT);

      e = Expression.crefExp(cref);
      tp = Expression.typeof(e);
      startExp = Expression.makePureBuiltinCall("$_start", {e}, tp);
      e1 = DAE.BINARY(crefExp, DAE.SUB(DAE.T_REAL_DEFAULT), startExp);

      eqn = BackendDAE.RESIDUAL_EQUATION(e1, DAE.emptyElementSource, BackendDAE.EQ_ATTR_DEFAULT_INITIAL);
    then (var,eqn::eqns);

    else (inVar,inEqs);
  end matchcontinue;
end generateImplicitInitialEquations;

protected function generateImplicitInitialEquationsForParameters "author: lochel
  Helper for collectInitialEquations.
  This function generates implicit initial equations for unfixed parameters."
  input BackendDAE.Var inVar;
  input list<BackendDAE.Equation> inEqs;
  output BackendDAE.Var outVar;
  output list<BackendDAE.Equation> outEqs;
algorithm
  (outVar,outEqs) := matchcontinue (inVar,inEqs)
  local
    BackendDAE.Var var;
    BackendDAE.Equation eqn;
    list<BackendDAE.Equation> eqns;
    DAE.Exp e, e1, crefExp, bindExp;
    DAE.ComponentRef cref;

    case (var as BackendDAE.VAR(varName=cref, varKind=BackendDAE.PARAM(), bindExp=SOME(bindExp)), eqns) equation
      false = BackendVariable.varFixed(var);

      crefExp = DAE.CREF(cref, DAE.T_REAL_DEFAULT);

      _ = Expression.crefExp(cref);
      e1 = DAE.BINARY(crefExp, DAE.SUB(DAE.T_REAL_DEFAULT), bindExp);

      eqn = BackendDAE.RESIDUAL_EQUATION(e1, DAE.emptyElementSource, BackendDAE.EQ_ATTR_DEFAULT_INITIAL);
    then (var,eqn::eqns);

    else (inVar,inEqs);
  end matchcontinue;
end generateImplicitInitialEquationsForParameters;

public function convertResidualsIntoSolvedEquations "author: lochel
  This function converts residuals into solved equations of the following form:
    e.g.: 0 = a+b -> $res1 = a+b"
  input list<BackendDAE.Equation> inResidualList;
  output list<BackendDAE.Equation> outEquationList;
  output list<BackendDAE.Var> outVariableList;
algorithm
  (outEquationList, outVariableList) := convertResidualsIntoSolvedEquations2(inResidualList, 1, {}, {});
end convertResidualsIntoSolvedEquations;

protected function convertResidualsIntoSolvedEquations2 "author: lochel
  This is a helper function of convertResidualsIntoSolvedEquations."
  input list<BackendDAE.Equation> inEquationList;
  input Integer inIndex;
  input list<BackendDAE.Equation> iEquationList;
  input list<BackendDAE.Var> iVariableList;
  output list<BackendDAE.Equation> outEquationList;
  output list<BackendDAE.Var> outVariableList;
algorithm
  (outEquationList, outVariableList) := matchcontinue(inEquationList, inIndex, iEquationList, iVariableList)
    local
      Integer index;
      list<BackendDAE.Equation> restEquationList;
      list<BackendDAE.Equation> equationList;
      list<BackendDAE.Var> variableList;

      DAE.Exp expVarName;
      DAE.Exp exp;
      DAE.ElementSource source "origin of equation";

      String varName, errorMessage;
      DAE.ComponentRef componentRef;
      BackendDAE.Equation currEquation;
      BackendDAE.Var currVariable;
      BackendDAE.EquationAttributes eqAttr;

    case({}, _, _ , _)
    then (listReverse(iEquationList), listReverse(iVariableList));

    case((BackendDAE.RESIDUAL_EQUATION(exp=exp,source=source,attr=eqAttr))::restEquationList, index,_,_) equation
      varName = "$res" + intString(index);
      componentRef = DAE.CREF_IDENT(varName, DAE.T_REAL_DEFAULT, {});
      expVarName = DAE.CREF(componentRef, DAE.T_REAL_DEFAULT);
      currEquation = BackendDAE.EQUATION(expVarName, exp, source, eqAttr);

      currVariable = BackendDAE.VAR(componentRef, BackendDAE.VARIABLE(), DAE.OUTPUT(), DAE.NON_PARALLEL(), DAE.T_REAL_DEFAULT, NONE(), NONE(), {}, DAE.emptyElementSource, NONE(), NONE(), DAE.NON_CONNECTOR());

      (equationList, variableList) = convertResidualsIntoSolvedEquations2(restEquationList, index+1,currEquation::iEquationList,currVariable::iVariableList);
    then (equationList, variableList);

    case(currEquation::_, _,_,_) equation
      errorMessage = "./Compiler/BackEnd/BackendDAEOptimize.mo: function convertResidualsIntoSolvedEquations2 failed: " + BackendDump.equationString(currEquation);
      Error.addMessage(Error.INTERNAL_ERROR, {errorMessage});
    then fail();

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"./Compiler/BackEnd/BackendDAEOptimize.mo: function convertResidualsIntoSolvedEquations2 failed"});
    then fail();
  end matchcontinue;
end convertResidualsIntoSolvedEquations2;

// =============================================================================
// parallel back end stuff (TLM)
//
// =============================================================================

public function collapseIndependentBlocks
  input BackendDAE.BackendDAE inDAE;
  output BackendDAE.BackendDAE outDAE;
protected
  BackendDAE.EqSystem syst;
  list<BackendDAE.EqSystem> systs;
  BackendDAE.Shared shared;
algorithm
  BackendDAE.DAE(systs, shared) := inDAE;
  // We can use listReduce as if there is no eq-system something went terribly wrong
  syst := List.reduce(systs, mergeIndependentBlocks);
  outDAE := BackendDAE.DAE({syst}, shared);
end collapseIndependentBlocks;

protected function mergeIndependentBlocks
  input BackendDAE.EqSystem syst1;
  input BackendDAE.EqSystem syst2;
  output BackendDAE.EqSystem syst;
protected
  BackendDAE.Variables vars, vars1, vars2;
  BackendDAE.EquationArray eqs, eqs1, eqs2;
  BackendDAE.StateSets stateSets, statSets1;
algorithm
  BackendDAE.EQSYSTEM(orderedVars=vars1, orderedEqs=eqs1, stateSets=stateSets) := syst1;
  BackendDAE.EQSYSTEM(orderedVars=vars2, orderedEqs=eqs2, stateSets=statSets1) := syst2;
  vars := BackendVariable.mergeVariables(vars2, vars1);
  eqs := BackendEquation.addEquations(BackendEquation.equationList(eqs2), eqs1);
  stateSets := listAppend(stateSets, statSets1);
  syst := BackendDAE.EQSYSTEM(vars, eqs, NONE(), NONE(), BackendDAE.NO_MATCHING(), stateSets, BackendDAE.UNKNOWN_PARTITION());
end mergeIndependentBlocks;

public function partitionIndependentBlocks
  "Finds independent partitions of the equation system by "
  input BackendDAE.BackendDAE dlow;
  output BackendDAE.BackendDAE outDlow;
algorithm
  outDlow := match (dlow)
    local
      BackendDAE.EqSystem syst;
      list<BackendDAE.EqSystem> systs;
      BackendDAE.Shared shared;

    case (BackendDAE.DAE({syst},shared))
      equation
        (systs,shared) = partitionIndependentBlocksHelper(syst,shared,Error.getNumErrorMessages(),false);
      then BackendDAE.DAE(systs,shared);
    else // TODO: Improve support for partitioned systems of equations
      equation
        BackendDAE.DAE({syst},shared) = collapseIndependentBlocks(dlow);
        (systs,shared) = partitionIndependentBlocksHelper(syst,shared,Error.getNumErrorMessages(),false);
      then BackendDAE.DAE(systs,shared);
  end match;
end partitionIndependentBlocks;

public function partitionIndependentBlocksHelper
  "Finds independent partitions of the equation system by "
  input BackendDAE.EqSystem isyst;
  input BackendDAE.Shared ishared;
  input Integer numErrorMessages;
  input Boolean throwNoError;
  output list<BackendDAE.EqSystem> systs;
  output BackendDAE.Shared oshared;
algorithm
  (systs,oshared) := matchcontinue (isyst,ishared,numErrorMessages,throwNoError)
    local
      BackendDAE.IncidenceMatrix m,mT;
      array<Integer> ixs;
      Boolean b;
      Integer i;
      BackendDAE.Shared shared;
      BackendDAE.EqSystem syst;
      DAE.FunctionTree funcs;
    case (syst,shared,_,_)
      equation
        // print("partitionIndependentBlocks: TODO: Implement me\n");
        funcs = BackendDAEUtil.getFunctions(ishared);
        (syst,m,mT) = BackendDAEUtil.getIncidenceMatrixfromOption(syst,BackendDAE.NORMAL(),SOME(funcs));
        ixs = arrayCreate(arrayLength(m),0);
        // ixsT = arrayCreate(arrayLength(mT),0);
        i = SynchronousFeatures.partitionIndependentBlocks0(m,mT,ixs);
        // i2 = SynchronousFeatures.partitionIndependentBlocks0(mT,m,ixsT);
        b = i > 1;
        // bcall2(b,BackendDump.dumpBackendDAE,BackendDAE.DAE({syst},shared), "partitionIndependentBlocksHelper");
        // printPartition(b,ixs);
        systs = if b then SynchronousFeatures.partitionIndependentBlocksSplitBlocks(i,syst,ixs,mT,throwNoError) else {syst};
        // print("Number of partitioned systems: " + intString(listLength(systs)) + "\n");
        // List.map1_0(systs, BackendDump.dumpEqSystem, "System");
      then (systs,shared);
    else
      equation
        Error.assertion(not (numErrorMessages==Error.getNumErrorMessages()),"BackendDAEOptimize.partitionIndependentBlocks failed without good error message",Absyn.dummyInfo);
      then fail();
  end matchcontinue;
end partitionIndependentBlocksHelper;


// =============================================================================
// residual stuff ... for whatever reason
//
// =============================================================================

public function residualForm
  "Puts equations like x=y in the form of 0=x-y"
  input BackendDAE.BackendDAE dlow;
  output BackendDAE.BackendDAE odlow;
algorithm
  odlow := BackendDAEUtil.mapEqSystem1(dlow,residualForm1,1);
end residualForm;

protected function residualForm1
  "Puts equations like x=y in the form of 0=x-y"
  input BackendDAE.EqSystem syst;
  input Integer i;
  input BackendDAE.Shared shared;
  output BackendDAE.EqSystem osyst;
  output BackendDAE.Shared oshared;
protected
  BackendDAE.EquationArray eqs;
algorithm
  BackendDAE.EQSYSTEM(orderedEqs=eqs) := syst;
  (_,_) := BackendEquation.traverseBackendDAEEqnsWithUpdate(eqs, residualForm2, 1);
  osyst := syst;
  oshared := shared;
end residualForm1;

protected function residualForm2
  input BackendDAE.Equation inEq;
  input Integer ii;
  output BackendDAE.Equation outEq;
  output Integer oi;
algorithm
  (outEq,oi) := matchcontinue (inEq,ii)
    local
      tuple<BackendDAE.Equation,Integer> ntpl;
      DAE.Exp e1,e2,e;
      DAE.ElementSource source;
      Integer i;
      BackendDAE.EquationAttributes eqAttr;

    case (BackendDAE.EQUATION(e1,e2,source,eqAttr),i)
      equation
        // This is ok, because EQUATION is not an array equation :D
        DAE.T_REAL() = Expression.typeof(e1);
        false = Expression.isZero(e1) or Expression.isZero(e2);
        e = DAE.BINARY(e1,DAE.SUB(DAE.T_REAL_DEFAULT),e2);
        (e,_) = ExpressionSimplify.simplify(e);
        source = DAEUtil.addSymbolicTransformation(source, DAE.OP_RESIDUAL(e1,e2,e));
      then (BackendDAE.EQUATION(DAE.RCONST(0.0),e,source,eqAttr),i);
    else (inEq,ii);
  end matchcontinue;
end residualForm2;

// =============================================================================
// countOperations
//
// =============================================================================

public function countOperations "author: Frenkel TUD 2011-05"
  input BackendDAE.BackendDAE inDAE;
  output BackendDAE.BackendDAE outDAE;
algorithm
  outDAE := matchcontinue(inDAE)
    case (_)
      equation
        true = Flags.isSet(Flags.COUNT_OPERATIONS);
        (outDAE,_) = BackendDAEUtil.mapEqSystemAndFold(inDAE,countOperations0,false);
      then
        outDAE;
    else inDAE;
  end matchcontinue;
end countOperations;

protected function countOperations0 "author: Frenkel TUD 2011-05"
  input BackendDAE.EqSystem isyst;
  input tuple<BackendDAE.Shared,Boolean> sharedChanged;
  output BackendDAE.EqSystem osyst;
  output tuple<BackendDAE.Shared,Boolean> osharedChanged;
algorithm
  (osyst,osharedChanged) :=
    match(isyst,sharedChanged)
    local
      BackendDAE.Shared shared;
      Boolean b;
      Integer i1,i2,i3,i4;
      BackendDAE.StrongComponents comps;

    case (BackendDAE.EQSYSTEM(matching=BackendDAE.MATCHING(comps=comps)),(shared, b))
      equation
        ((i1,i2,i3,i4)) = countOperationstraverseComps(comps,isyst,shared,(0,0,0,0));
        print("Add Operations: " + intString(i1) + "\n");
        print("Mul Operations: " + intString(i2) + "\n");
        print("Oth Operations: " + intString(i3) + "\n");
        print("Trig Operations: " + intString(i4) + "\n");
      then
        (isyst,(shared,b));
  end match;
end countOperations0;

public function countOperationstraverseComps "author: Frenkel TUD 2012-05"
  input BackendDAE.StrongComponents inComps;
  input BackendDAE.EqSystem isyst;
  input BackendDAE.Shared ishared;
  input tuple<Integer,Integer,Integer,Integer> inTpl;
  output tuple<Integer,Integer,Integer,Integer> outTpl;
algorithm
  outTpl :=
  matchcontinue (inComps,isyst,ishared,inTpl)
    local
      Integer e, i1,i2,i3,i4, i1_1,i2_1,i3_1,i4_1;
      BackendDAE.StrongComponent comp,comp1;
      BackendDAE.StrongComponents rest;
      BackendDAE.EquationArray eqns, tmpEqns;
      BackendDAE.Equation eqn;
      tuple<Integer,Integer,Integer,Integer> tpl;
      list<BackendDAE.Equation> eqnlst;
      BackendDAE.Jacobian jac;
      list<BackendDAE.Var> varlst;
      list<DAE.Exp> explst;
      DAE.FunctionTree funcs;
      list<tuple<Integer,list<Integer>>> eqnvartpllst;
      list<Integer> vlst;
    case ({},_,_,_) then inTpl;
    case (BackendDAE.SINGLEEQUATION(eqn=e)::rest,_,_,_)
      equation
        eqns = BackendEquation.getEqnsFromEqSystem(isyst);
        eqn = BackendEquation.equationNth1(eqns, e);
        (_,tpl) = BackendEquation.traverseBackendDAEExpsEqn(eqn,countOperationsExp,inTpl);
      then
         countOperationstraverseComps(rest,isyst,ishared,tpl);
    case ((comp as BackendDAE.EQUATIONSYSTEM(jac=jac,jacType=BackendDAE.JAC_LINEAR()))::rest,_,BackendDAE.SHARED(functionTree=funcs),_)
      equation
        (eqnlst,varlst,_) = BackendDAETransform.getEquationAndSolvedVar(comp, BackendEquation.getEqnsFromEqSystem(isyst), BackendVariable.daeVars(isyst));
        tpl = addJacSpecificOperations(listLength(eqnlst),inTpl);
        tpl = countOperationsJac(jac,tpl);
        (explst,_) = BackendDAEUtil.getEqnSysRhs(BackendEquation.listEquation(eqnlst),BackendVariable.listVar1(varlst),SOME(funcs));
        (_,tpl) = Expression.traverseExpList(explst,countOperationsExp,tpl);
      then
         countOperationstraverseComps(rest,isyst,ishared,tpl);
    case ((comp as BackendDAE.EQUATIONSYSTEM())::rest,_,_,_)
      equation
        (eqnlst,_,_) = BackendDAETransform.getEquationAndSolvedVar(comp, BackendEquation.getEqnsFromEqSystem(isyst), BackendVariable.daeVars(isyst));
        tpl = BackendDAEUtil.traverseBackendDAEExpsEqns(BackendEquation.listEquation(eqnlst),countOperationsExp,inTpl);
      then
        countOperationstraverseComps(rest,isyst,ishared,tpl);
    case (BackendDAE.SINGLEARRAY(eqn=e)::rest,_,_,_)
      equation
         eqn = BackendEquation.equationNth1(BackendEquation.getEqnsFromEqSystem(isyst), e);
         (_,tpl) = BackendEquation.traverseBackendDAEExpsEqn(eqn,countOperationsExp,inTpl);
      then
         countOperationstraverseComps(rest,isyst,ishared,tpl);
    case (BackendDAE.SINGLEIFEQUATION(eqn=e)::rest,_,_,_)
      equation
         eqn = BackendEquation.equationNth1(BackendEquation.getEqnsFromEqSystem(isyst), e);
         (_,tpl) = BackendEquation.traverseBackendDAEExpsEqn(eqn,countOperationsExp,inTpl);
      then
         countOperationstraverseComps(rest,isyst,ishared,tpl);
    case (BackendDAE.SINGLEALGORITHM(eqn=e)::rest,_,_,_)
      equation
         eqn = BackendEquation.equationNth1(BackendEquation.getEqnsFromEqSystem(isyst), e);
         (_,tpl) = BackendEquation.traverseBackendDAEExpsEqn(eqn,countOperationsExp,inTpl);
      then
         countOperationstraverseComps(rest,isyst,ishared,tpl);
    case (BackendDAE.SINGLECOMPLEXEQUATION(eqn=e)::rest,_,_,_)
      equation
         eqn = BackendEquation.equationNth1(BackendEquation.getEqnsFromEqSystem(isyst), e);
         (_,tpl) = BackendEquation.traverseBackendDAEExpsEqn(eqn,countOperationsExp,inTpl);
      then
         countOperationstraverseComps(rest,isyst,ishared,tpl);
    case (BackendDAE.SINGLEWHENEQUATION(eqn=e)::rest,_,_,_)
      equation
         eqn = BackendEquation.equationNth1(BackendEquation.getEqnsFromEqSystem(isyst), e);
         (_,tpl) = BackendEquation.traverseBackendDAEExpsEqn(eqn,countOperationsExp,inTpl);
      then
         countOperationstraverseComps(rest,isyst,ishared,tpl);
    case ((comp as BackendDAE.TORNSYSTEM(tearingvars=vlst, linear=true))::rest,_,BackendDAE.SHARED(functionTree=funcs),_)
      equation
        (eqnlst,varlst,_) = BackendDAETransform.getEquationAndSolvedVar(comp, BackendEquation.getEqnsFromEqSystem(isyst), BackendVariable.daeVars(isyst));
        tpl = addJacSpecificOperations(listLength(vlst),inTpl);
        tmpEqns = BackendEquation.listEquation(eqnlst);
        (explst,_) = BackendDAEUtil.getEqnSysRhs(tmpEqns,BackendVariable.listVar1(varlst),SOME(funcs));
        (_,tpl) = Expression.traverseExpList(explst,countOperationsExp,tpl);
      then
         countOperationstraverseComps(rest,isyst,ishared,tpl);
    case ((comp as BackendDAE.TORNSYSTEM(tearingvars=vlst, linear=false))::rest,_,BackendDAE.SHARED(),_)
      equation
        (eqnlst,_,_) = BackendDAETransform.getEquationAndSolvedVar(comp, BackendEquation.getEqnsFromEqSystem(isyst), BackendVariable.daeVars(isyst));
        ((i1_1,i2_1,i3_1,i4_1)) = addJacSpecificOperations(listLength(vlst),(0,0,0,0));
        (i1_1,i2_1,i3_1,i4_1) = (i1_1*3,i2_1*3,i3_1*3,i4_1*3);
        (i1,i2,i3,i4) = inTpl;
        tpl = (i1_1+i1,i2_1+i2,i3_1+i3,i4_1+i4);
        tpl = BackendDAEUtil.traverseBackendDAEExpsEqns(BackendEquation.listEquation(eqnlst),countOperationsExp,tpl);
        //print("countOperationstraverseComps: Nonlinear systems are in beta state!\n");
      then
          countOperationstraverseComps(rest,isyst,ishared,tpl);
    case (_::rest,_,_,_)
      equation
        true = Flags.isSet(Flags.FAILTRACE);
        Debug.traceln("BackendDAEOptimize.countOperationstraverseComps failed!");
      then
         countOperationstraverseComps(rest,isyst,ishared,inTpl);
    case (_::rest,_,_,_)
      then
        countOperationstraverseComps(rest,isyst,ishared,inTpl);
  end matchcontinue;
end countOperationstraverseComps;

protected function countOperationsJac
  input BackendDAE.Jacobian inJac;
  input tuple<Integer,Integer,Integer,Integer> inTpl;
  output tuple<Integer,Integer,Integer,Integer> outTpl;
algorithm
  outTpl := match(inJac,inTpl)
    local
      list<tuple<Integer, Integer, BackendDAE.Equation>> jac;
      case (BackendDAE.FULL_JACOBIAN(NONE()),_) then inTpl;
      case (BackendDAE.FULL_JACOBIAN(SOME(jac)),_)
        then List.fold(jac,countOperationsJac1,inTpl);
      /* TODO: implement for GENERIC_JACOBIAN */
      case (_,_) then inTpl;
  end match;
end countOperationsJac;

protected function countOperationsJac1
  input tuple<Integer, Integer, BackendDAE.Equation> inJac;
  input tuple<Integer,Integer,Integer,Integer> inTpl;
  output tuple<Integer,Integer,Integer,Integer> outTpl;
algorithm
  (_,outTpl) := BackendEquation.traverseBackendDAEExpsEqn(Util.tuple33(inJac),countOperationsExp,inTpl);
end countOperationsJac1;

protected function addJacSpecificOperations
  input Integer n;
  input tuple<Integer,Integer,Integer,Integer> inTpl;
  output tuple<Integer,Integer,Integer,Integer> outTpl;
protected
  Integer i1,i2,i3,i4,i1_1,i2_1,n2,n3;
algorithm
  (i1,i2,i3,i4) := inTpl;
  n2 := n*n;
  n3 := n*n*n;
  i1_1 := intDiv(2*n3+3*n2-5*n,6) + i1;
  i2_1 := intDiv(2*n3+6*n2-2*n,6) + i2;
  outTpl := (i1_1,i2_1,i3,i4);
end addJacSpecificOperations;

public function countOperationsExp
  input DAE.Exp inExp;
  input tuple<Integer,Integer,Integer,Integer> inTpl;
  output DAE.Exp outExp;
  output tuple<Integer,Integer,Integer,Integer> outTpl;
algorithm
  (outExp,outTpl) := Expression.traverseExp(inExp,traversecountOperationsExp,inTpl);
end countOperationsExp;

protected function traversecountOperationsExp
  input DAE.Exp inExp;
  input tuple<Integer,Integer,Integer,Integer> inTuple;
  output DAE.Exp outExp;
  output tuple<Integer,Integer,Integer,Integer> outTuple;
algorithm
  (outExp,outTuple) := matchcontinue (inExp,inTuple)
    local
      DAE.Exp e;
      Integer i1,i2,i3,i4,i1_1,i2_1,i3_1,i4_1,iexp2;
      Real rexp2;
      DAE.Operator op;
      String opName;
      Absyn.Path path;
      list<DAE.Exp> expLst;
    case (e as DAE.BINARY(operator=DAE.POW(),exp2=DAE.RCONST(rexp2)),(i1,i2,i3,i4)) equation
      iexp2 = realInt(rexp2);
      true = realEq(rexp2, intReal(iexp2));
      i2_1 = i2+intAbs(iexp2)-1;
      then (e, (i1,i2_1,i3,i4));
    case (e as DAE.BINARY(operator=op),(i1,i2,i3,i4)) equation
      (i1_1,i2_1,i3_1,i4_1) = countOperator(op,i1,i2,i3,i4);
      then (e, (i1_1,i2_1,i3_1,i4_1));
    case (e as DAE.CALL(path=Absyn.IDENT(name=opName)),(i1,i2,i3,i4)) equation
      true = stringEq(opName,"sin") or stringEq(opName,"cos") or stringEq(opName,"tan");
      (i1_1,i2_1,i3_1,i4_1) = (i1,i2,i3,i4+1);
      then (e, (i1_1,i2_1,i3_1,i4_1));
    else (inExp,inTuple);
  end matchcontinue;
end traversecountOperationsExp;

protected function countOperator
  input DAE.Operator op;
  input Integer inInt1;
  input Integer inInt2;
  input Integer inInt3;
  input Integer inInt4;
  output Integer outInt1;
  output Integer outInt2;
  output Integer outInt3;
  output Integer outInt4;
algorithm
  (outInt1,outInt2,outInt3,outInt4) := match(op, inInt1, inInt2, inInt3, inInt4)
    local
      DAE.Type tp;
      Integer i;
    case (DAE.ADD(),_,_,_,_)
      then (inInt1+1,inInt2,inInt3,inInt4);
    case (DAE.SUB(),_,_,_,_)
      then (inInt1+1,inInt2,inInt3,inInt4);
    case (DAE.MUL(),_,_,_,_)
      then (inInt1,inInt2+1,inInt3,inInt4);
    case (DAE.DIV(),_,_,_,_)
      then (inInt1,inInt2+1,inInt3,inInt4);
    case (DAE.POW(),_,_,_,_)
      then (inInt1,inInt2,inInt3+1,inInt4);
    case (DAE.UMINUS(),_,_,_,_)
      then (inInt1,inInt2,inInt3+1,inInt4);
    case (DAE.UMINUS_ARR(ty=tp),_,_,_,_) equation
      i = Expression.sizeOf(tp);
      then (inInt1,inInt2,inInt3+i,inInt4);
    case (DAE.ADD_ARR(ty=tp),_,_,_,_) equation
      i = Expression.sizeOf(tp);
      then (inInt1+i,inInt2,inInt3,inInt4);
    case (DAE.SUB_ARR(ty=tp),_,_,_,_) equation
      i = Expression.sizeOf(tp);
      then (inInt1+i,inInt2,inInt3,inInt4);
    case (DAE.MUL_ARR(ty=tp),_,_,_,_) equation
      i = Expression.sizeOf(tp);
      then (inInt1,inInt2+i,inInt3,inInt4);
    case (DAE.DIV_ARR(ty=tp),_,_,_,_) equation
      i = Expression.sizeOf(tp);
      then (inInt1,inInt2+i,inInt3,inInt4);
    case (DAE.MUL_ARRAY_SCALAR(ty=tp),_,_,_,_) equation
      i = Expression.sizeOf(tp);
      then (inInt1,inInt2+i,inInt3,inInt4);
    case (DAE.ADD_ARRAY_SCALAR(),_,_,_,_)
      then (inInt1+1,inInt2,inInt3,inInt4);
    case (DAE.SUB_SCALAR_ARRAY(),_,_,_,_)
      then (inInt1+1,inInt2,inInt3,inInt4);
    case (DAE.MUL_SCALAR_PRODUCT(),_,_,_,_)
      then (inInt1,inInt2+1,inInt3,inInt4);
    case (DAE.MUL_MATRIX_PRODUCT(),_,_,_,_)
      then (inInt1,inInt2+1,inInt3,inInt4);
    case (DAE.DIV_ARRAY_SCALAR(),_,_,_,_)
      then (inInt1,inInt2+1,inInt3,inInt4);
    case (DAE.DIV_SCALAR_ARRAY(),_,_,_,_)
      then (inInt1,inInt2+1,inInt3,inInt4);
    case (DAE.POW_ARRAY_SCALAR(),_,_,_,_)
      then (inInt1,inInt2,inInt3+1,inInt4);
    case (DAE.POW_SCALAR_ARRAY(),_,_,_,_)
      then (inInt1,inInt2,inInt3+1,inInt4);
    case (DAE.POW_ARR(),_,_,_,_)
      then (inInt1,inInt2,inInt3+1,inInt4);
    case (DAE.POW_ARR2(),_,_,_,_)
      then (inInt1,inInt2,inInt3+1,inInt4);
    case (DAE.AND(),_,_,_,_)
      then (inInt1,inInt2,inInt3+1,inInt4);
    case (DAE.OR(),_,_,_,_)
      then (inInt1,inInt2,inInt3+1,inInt4);
    case (DAE.NOT(),_,_,_,_)
      then (inInt1,inInt2,inInt3+1,inInt4);
    case (DAE.NOT(),_,_,_,_)
      then (inInt1,inInt2,inInt3+1,inInt4);
    case (DAE.LESS(),_,_,_,_)
      then (inInt1,inInt2,inInt3+1,inInt4);
    case (DAE.LESSEQ(),_,_,_,_)
      then (inInt1,inInt2,inInt3+1,inInt4);
    case (DAE.GREATER(),_,_,_,_)
      then (inInt1,inInt2,inInt3+1,inInt4);
    case (DAE.GREATEREQ(),_,_,_,_)
      then (inInt1,inInt2,inInt3+1,inInt4);
    case (DAE.EQUAL(),_,_,_,_)
      then (inInt1,inInt2,inInt3+1,inInt4);
    case (DAE.NEQUAL(),_,_,_,_)
      then (inInt1,inInt2,inInt3+1,inInt4);
    case (DAE.USERDEFINED(),_,_,_,_)
      then (inInt1,inInt2,inInt3+1,inInt4);
    else
      then(inInt1,inInt2,inInt3+1,inInt4);
  end match;
end countOperator;


// =============================================================================
// simplify if equations
//
// =============================================================================

public function simplifyIfEquations "author: Frenkel TUD 2012-07
  This function traveres all if equations and if expressions and tries to
  simplify it by using the information from evaluated parameters."
  input BackendDAE.BackendDAE dae;
  output BackendDAE.BackendDAE odae;
algorithm
  odae := BackendDAEUtil.mapEqSystem(dae, simplifyIfEquationsWork);
end simplifyIfEquations;

protected function simplifyIfEquationsWork "author: Frenkel TUD 2012-07
  This function traveres all if equations and if expressions and tries to
  simplify it by using the information from evaluated parameters."
  input BackendDAE.EqSystem isyst;
  input BackendDAE.Shared ishared;
  output BackendDAE.EqSystem osyst;
  output BackendDAE.Shared oshared;
algorithm
  (osyst,oshared) := matchcontinue (isyst, ishared)
    local
      BackendDAE.Variables vars,knvars;
      BackendDAE.EquationArray eqns;
      list<BackendDAE.Equation> eqnslst,asserts;
      BackendDAE.EqSystem syst;
      BackendDAE.Shared shared;
      BackendDAE.StateSets stateSets;
      BackendDAE.BaseClockPartitionKind partitionKind;

    case (BackendDAE.EQSYSTEM(orderedVars=vars,orderedEqs=eqns,stateSets=stateSets,partitionKind=partitionKind),shared as BackendDAE.SHARED(knownVars=knvars))
      equation
        // traverse the equations
        eqnslst = BackendEquation.equationList(eqns);
        // traverse equations in reverse order, than branch equations of if equaitions need no reverse
        ((eqnslst,asserts,true)) = List.fold1(listReverse(eqnslst), simplifyIfEquationsFinder, knvars, ({},{},false));
        eqns = BackendEquation.listEquation(eqnslst);
        syst = BackendDAE.EQSYSTEM(vars,eqns,NONE(),NONE(),BackendDAE.NO_MATCHING(),stateSets,partitionKind);
        shared = BackendEquation.requationsAddDAE(asserts,shared);
      then (syst,shared);

    case (_,_)
    then (isyst,ishared);
  end matchcontinue;
end simplifyIfEquationsWork;

protected function simplifyIfEquationsFinder
"author: Frenkel TUD 2012-07
  helper for simplifyIfEquations"
  input BackendDAE.Equation inElem;
  input BackendDAE.Variables inConstArg;
  input tuple<list<BackendDAE.Equation>,list<BackendDAE.Equation>,Boolean> inArg;
  output tuple<list<BackendDAE.Equation>,list<BackendDAE.Equation>,Boolean> outArg;
algorithm
  outArg := matchcontinue(inElem,inConstArg,inArg)
    local
      list<DAE.Exp> explst;
      list<BackendDAE.Equation> eqnslst,acc,asserts,asserts1;
      list<list<BackendDAE.Equation>> eqnslstlst;
      DAE.ElementSource source;
      BackendDAE.Variables knvars;
      Boolean b;
      BackendDAE.Equation eqn;
      BackendDAE.EquationAttributes attr;

    case (BackendDAE.IF_EQUATION(conditions=explst, eqnstrue=eqnslstlst, eqnsfalse=eqnslst, source=source, attr=attr), knvars, (acc, asserts, _))
      equation
        // check conditions
        (explst,_) = Expression.traverseExpList(explst, simplifyEvaluatedParamter, (knvars,false));
        explst = ExpressionSimplify.simplifyList(explst, {});
        // simplify if equation
        (acc,asserts1) = simplifyIfEquation(explst,eqnslstlst,eqnslst,{},{},source,knvars,acc,attr);
        asserts = listAppend(asserts,asserts1);
      then
        ((acc, asserts, true));

    case (eqn,knvars,(acc,asserts,b))
      equation
        (eqn,(_,b)) = BackendEquation.traverseBackendDAEExpsEqn(eqn, simplifyIfExpevaluatedParamter, (knvars,b));
      then
        ((eqn::acc,asserts,b));
  end matchcontinue;
end simplifyIfEquationsFinder;

protected function simplifyIfExpevaluatedParamter
  input DAE.Exp inExp;
  input tuple<BackendDAE.Variables,Boolean> tpl1;
  output DAE.Exp outExp;
  output tuple<BackendDAE.Variables,Boolean> tpl2;
algorithm
  (outExp,tpl2) := matchcontinue (inExp,tpl1)
    local
      BackendDAE.Variables knvars;
      DAE.Exp e1,e2,cond,expThen,expElse;
      Boolean b,b1;
    case (e1 as DAE.IFEXP(expCond=cond, expThen=expThen, expElse=expElse),(knvars,b))
      equation
        (cond,(_,b1)) = Expression.traverseExp(cond, simplifyEvaluatedParamter, (knvars,false));
        e2 = if b1 then DAE.IFEXP(cond,expThen,expElse) else e1;
        (e2,_) = ExpressionSimplify.condsimplify(b1,e2);
      then (e2,(knvars,b or b1));
    else (inExp,tpl1);
  end matchcontinue;
end simplifyIfExpevaluatedParamter;

protected function simplifyEvaluatedParamter
  input DAE.Exp inExp;
  input tuple<BackendDAE.Variables,Boolean> tpl1;
  output DAE.Exp outExp;
  output tuple<BackendDAE.Variables,Boolean> tpl2;
algorithm
  (outExp,tpl2) := matchcontinue (inExp,tpl1)
    local
      BackendDAE.Variables knvars;
      DAE.ComponentRef cr;
      BackendDAE.Var v;
      DAE.Exp e;
    case (DAE.CREF(componentRef = cr),(knvars,_))
      equation
        (v::{},_::{}) = BackendVariable.getVar(cr,knvars);
        true = BackendVariable.isFinalVar(v);
        e = BackendVariable.varBindExpStartValue(v);
      then (e,(knvars,true));
    else (inExp,tpl1);
  end matchcontinue;
end simplifyEvaluatedParamter;

protected function simplifyIfEquation
"author: Frenkel TUD 2012-07
  helper for simplifyIfEquations"
  input list<DAE.Exp> conditions;
  input list<list<BackendDAE.Equation>> theneqns;
  input list<BackendDAE.Equation> elseenqs;
  input list<DAE.Exp> conditions1;
  input list<list<BackendDAE.Equation>> theneqns1;
  input DAE.ElementSource source;
  input BackendDAE.Variables knvars;
  input list<BackendDAE.Equation> inEqns;
  input BackendDAE.EquationAttributes inEqAttr;
  output list<BackendDAE.Equation> outEqns;
  output list<BackendDAE.Equation> outAsserts;
algorithm
  (outEqns,outAsserts) := match(conditions,theneqns,elseenqs,conditions1,theneqns1,source,knvars,inEqns,inEqAttr)
    local
      DAE.Exp e;
      list<DAE.Exp> explst;
      list<list<BackendDAE.Equation>> eqnslst;
      list<BackendDAE.Equation> eqns,elseenqs1,asserts;

    // no true case left with condition<>false
    case ({},{},_,{},{},_,_,_,_)
      equation
        // simplify nested if equations
        ((eqns,asserts,_)) = List.fold1(listReverse(elseenqs), simplifyIfEquationsFinder, knvars, ({},{},false));
      then
        (listAppend(eqns,inEqns),asserts);
    // true case left with condition<>false
    case ({},{},_,_,_,_,_,_,_)
      equation
        explst = listReverse(conditions1);
        eqnslst = listReverse(theneqns1);
        // simplify nested if equations
        ((elseenqs1,asserts,_)) = List.fold1(listReverse(elseenqs), simplifyIfEquationsFinder, knvars, ({},{},false));
        elseenqs1 = listAppend(elseenqs1,asserts);
        (eqnslst,elseenqs1,asserts) = simplifyIfEquationAsserts(explst,eqnslst,elseenqs1,{},{},{});
        eqns = simplifyIfEquation1(explst,eqnslst,elseenqs1,source,knvars,inEqns,inEqAttr);
      then
        (eqns,asserts);
    // if true and first use it
    case(DAE.BCONST(true)::_,eqns::_,_,{},_,_,_,_,_)
      equation
        // simplify nested if equations
        ((eqns,asserts,_)) = List.fold1(listReverse(eqns), simplifyIfEquationsFinder, knvars, ({},{},false));
      then
        (listAppend(eqns,inEqns),asserts);
    // if true and not first use it as new else
    case(DAE.BCONST(true)::_,eqns::_,_,_,_,_,_,_,_)
      equation
        explst = listReverse(conditions1);
        eqnslst = listReverse(theneqns1);
        // simplify nested if equations
        ((elseenqs1,asserts,_)) = List.fold1(listReverse(eqns), simplifyIfEquationsFinder, knvars, ({},{},false));
        elseenqs1 = listAppend(elseenqs1,asserts);
        (eqnslst,elseenqs1,asserts) = simplifyIfEquationAsserts(explst,eqnslst,elseenqs1,{},{},{});
        eqns = simplifyIfEquation1(explst,eqnslst,elseenqs1,source,knvars,inEqns,inEqAttr);
      then
        (eqns,asserts);
    // if false skip it
    case(DAE.BCONST(false)::explst,_::eqnslst,_,_,_,_,_,_,_)
      equation
        (eqns,asserts) = simplifyIfEquation(explst,eqnslst,elseenqs,conditions1,theneqns1,source,knvars,inEqns,inEqAttr);
      then
        (eqns,asserts);
    // all other cases
    case(e::explst,eqns::eqnslst,_,_,_,_,_,_,_)
      equation
        // simplify nested if equations
        ((eqns,asserts,_)) = List.fold1(listReverse(eqns), simplifyIfEquationsFinder, knvars, ({},{},false));
        eqns = listAppend(eqns,asserts);
        (eqns,asserts) = simplifyIfEquation(explst,eqnslst,elseenqs,e::conditions1,eqns::theneqns1,source,knvars,inEqns,inEqAttr);
      then
        (eqns,asserts);
  end match;
end simplifyIfEquation;

protected function simplifyIfEquation1
"author: Frenkel TUD 2012-07
  helper for simplifyIfEquations"
  input list<DAE.Exp> conditions;
  input list<list<BackendDAE.Equation>> theneqns;
  input list<BackendDAE.Equation> elseenqs;
  input DAE.ElementSource source;
  input BackendDAE.Variables knvars;
  input list<BackendDAE.Equation> inEqns;
  input BackendDAE.EquationAttributes inEqAttr;
  output list<BackendDAE.Equation> outEqns;
algorithm
  outEqns := matchcontinue(conditions,theneqns,elseenqs,source,knvars,inEqns,inEqAttr)
    local
      list<DAE.Exp> fbsExp;
      list<list<DAE.Exp>> tbsExp;
      list<BackendDAE.Equation> eqns;
      HashTable2.HashTable ht;
      list<tuple<DAE.ComponentRef,DAE.Exp>> crexplst;

    // true case left with condition<>false
    case (_,_,_,_,_,_,_)
      equation
        _ = countEquationsInBranches(theneqns,elseenqs,source);
        // simplify if eqution
        // if .. then a=.. elseif .. then a=... else a=.. end if;
        // to
        // a=if .. then .. else if .. then else ..;
        ht = HashTable2.emptyHashTable();
        ht = simplifySolvedIfEqnsElse(elseenqs,ht);
        ht = simplifySolvedIfEqns(listReverse(conditions),listReverse(theneqns),ht);
        crexplst = BaseHashTable.hashTableList(ht);
        eqns = simplifySolvedIfEqns2(crexplst, inEqns, inEqAttr);
        // ToDo: check if the same cref is not used more than once on the lhs, merge sources
      then
        eqns;
    case (_,_,_,_,_,_,_)
      equation
        _ = countEquationsInBranches(theneqns,elseenqs,source);
        fbsExp = makeEquationLstToResidualExpLst(elseenqs);
        tbsExp = List.map(theneqns, makeEquationLstToResidualExpLst);
        eqns = makeEquationsFromResiduals(conditions, tbsExp, fbsExp, source, inEqAttr);
      then
        listAppend(eqns,inEqns);

    else then BackendDAE.IF_EQUATION(conditions,theneqns,elseenqs,source,inEqAttr)::inEqns;
  end matchcontinue;
end simplifyIfEquation1;

protected function simplifySolvedIfEqns2
  input list<tuple<DAE.ComponentRef,DAE.Exp>> crexplst;
  input list<BackendDAE.Equation> inEqns;
  input BackendDAE.EquationAttributes inEqAttr;
  output list<BackendDAE.Equation> outEqns;
algorithm
  outEqns := match(crexplst, inEqns, inEqAttr)
    local
      DAE.ComponentRef cr;
      DAE.Exp e,crexp;
      list<tuple<DAE.ComponentRef,DAE.Exp>> rest;

    case ({}, _, _)
    then inEqns;

    case ((cr,e)::rest,_, _)
      equation
        crexp = Expression.crefExp(cr);
      then
       simplifySolvedIfEqns2(rest, BackendDAE.EQUATION(crexp, e, DAE.emptyElementSource, inEqAttr)::inEqns, inEqAttr);
  end match;
end simplifySolvedIfEqns2;

protected function simplifySolvedIfEqns
"author: Frenkel TUD 2012-10
  helper for simplifyIfEquations"
  input list<DAE.Exp> conditions;
  input list<list<BackendDAE.Equation>> theneqns;
  input HashTable2.HashTable iHt;
  output HashTable2.HashTable oHt;
algorithm
  oHt := match(conditions,theneqns,iHt)
    local
      HashTable2.HashTable ht;
      DAE.Exp c;
      list<DAE.Exp> explst;
      list<BackendDAE.Equation> eqns;
      list<list<BackendDAE.Equation>> rest;
    case ({},{},_)
      then
        iHt;
    case (c::explst,eqns::rest,_)
      equation
        ht = simplifySolvedIfEqns1(c,eqns,iHt);
      then
        simplifySolvedIfEqns(explst,rest,ht);
  end match;
end simplifySolvedIfEqns;

protected function simplifySolvedIfEqns1
"author: Frenkel TUD 2012-10
  helper for simplifyIfEquations"
  input DAE.Exp condition;
  input list<BackendDAE.Equation> brancheqns;
  input HashTable2.HashTable iHt;
  output HashTable2.HashTable oHt;
algorithm
  oHt := match(condition,brancheqns,iHt)
    local
      DAE.ComponentRef cr;
      DAE.Exp e,exp;
      DAE.ElementSource source;
      HashTable2.HashTable ht;
      list<BackendDAE.Equation> rest;
    case (_,{},_)
      then
        iHt;
    case (_,BackendDAE.EQUATION(exp=DAE.CREF(componentRef=cr), scalar=e)::rest,_)
      equation
        false = Expression.expHasCref(e, cr);
        exp = BaseHashTable.get(cr, iHt);
        exp = DAE.IFEXP(condition, e, exp);
        ht = BaseHashTable.add((cr,exp), iHt);
      then
        simplifySolvedIfEqns1(condition,rest,ht);
    case (_,BackendDAE.EQUATION(exp=DAE.UNARY(operator=DAE.UMINUS(), exp=DAE.CREF(componentRef=cr)), scalar=e)::rest,_)
      equation
        false = Expression.expHasCref(e, cr);
        exp = BaseHashTable.get(cr, iHt);
        e = Expression.negate(e);
        exp = DAE.IFEXP(condition, e, exp);
        ht = BaseHashTable.add((cr,exp), iHt);
      then
        simplifySolvedIfEqns1(condition,rest,ht);
  end match;
end simplifySolvedIfEqns1;

protected function simplifySolvedIfEqnsElse
"author: Frenkel TUD 2012-10
  helper for simplifyIfEquations"
  input list<BackendDAE.Equation> elseenqs;
  input HashTable2.HashTable iHt;
  output HashTable2.HashTable oHt;
algorithm
  oHt := match(elseenqs,iHt)
    local
      DAE.ComponentRef cr;
      DAE.Exp e;
      DAE.ElementSource source;
      HashTable2.HashTable ht;
      list<BackendDAE.Equation> rest;
    case ({},_)
      then
        iHt;
    case (BackendDAE.EQUATION(exp=DAE.CREF(componentRef=cr), scalar=e)::rest,_)
      equation
        failure( _ = BaseHashTable.get(cr, iHt));
        false = Expression.expHasCref(e, cr);
        ht = BaseHashTable.add((cr,e), iHt);
      then
        simplifySolvedIfEqnsElse(rest,ht);
    case (BackendDAE.EQUATION(exp=DAE.UNARY(operator=DAE.UMINUS(), exp=DAE.CREF(componentRef=cr)), scalar=e)::rest,_)
      equation
        failure( _ = BaseHashTable.get(cr, iHt));
        false = Expression.expHasCref(e, cr);
        e = Expression.negate(e);
        ht = BaseHashTable.add((cr,e), iHt);
      then
        simplifySolvedIfEqnsElse(rest,ht);
  end match;
end simplifySolvedIfEqnsElse;

protected function simplifyIfEquationAsserts
"author: Frenkel TUD 2012-07
  helper for simplifyIfEquations"
  input list<DAE.Exp> conditions;
  input list<list<BackendDAE.Equation>> theneqns;
  input list<BackendDAE.Equation> elseenqs;
  input list<DAE.Exp> conditions1;
  input list<list<BackendDAE.Equation>> theneqns1;
  input list<BackendDAE.Equation> inEqns;
  output list<list<BackendDAE.Equation>> otheneqns;
  output list<BackendDAE.Equation> oelseenqs;
  output list<BackendDAE.Equation> outEqns;
algorithm
  (otheneqns,oelseenqs,outEqns) := match(conditions,theneqns,elseenqs,conditions1,theneqns1,inEqns)
    local
      DAE.Exp e;
      list<DAE.Exp> explst;
      list<BackendDAE.Equation> eqns,eqns1,beqns;
      list<list<BackendDAE.Equation>> eqnslst,eqnslst1;

    case (_,{},_,_,_,_)
      equation
        (beqns,eqns) = simplifyIfEquationAsserts1(elseenqs,NONE(),conditions1,{},inEqns);
      then
        (listReverse(theneqns1),beqns,eqns);
    case (e::explst,eqns::eqnslst,_,_,_,_)
      equation
        (beqns,eqns) = simplifyIfEquationAsserts1(eqns,SOME(e),conditions1,{},inEqns);
        (eqnslst1,eqns1,eqns) = simplifyIfEquationAsserts(explst,eqnslst,elseenqs,e::conditions1,beqns::theneqns1,eqns);
      then
        (eqnslst1,eqns1,eqns);
  end match;
end simplifyIfEquationAsserts;

protected function simplifyIfEquationAsserts1
"author: Frenkel TUD 2012-07
  helper for simplifyIfEquationAsserts"
  input list<BackendDAE.Equation> brancheqns;
  input Option<DAE.Exp> condition;
  input list<DAE.Exp> conditions "reversed";
  input list<BackendDAE.Equation> brancheqns1;
  input list<BackendDAE.Equation> inEqns;
  output list<BackendDAE.Equation> obrancheqns;
  output list<BackendDAE.Equation> outEqns;
algorithm
  (obrancheqns,outEqns) := match(brancheqns,condition,conditions,brancheqns1,inEqns)
    local
      DAE.Exp e,cond,msg,level;
      BackendDAE.Equation eqn;
      list<BackendDAE.Equation> eqns,beqns;
      Integer size;
      DAE.ElementSource source,source1;
      DAE.Expand crefExpand;
      BackendDAE.EquationAttributes eqAttr;

    case ({},_,_,_,_)
      then
        (listReverse(brancheqns1),inEqns);

    case (BackendDAE.ALGORITHM(size=size,alg=DAE.ALGORITHM_STMTS({DAE.STMT_ASSERT(cond=cond,msg=msg,level=level,source=source1)}),source=source,expand=crefExpand,attr=eqAttr)::eqns,NONE(),_,_,_)
      equation
        e = List.fold(conditions,makeIfExp,cond);
        (beqns,eqns) =  simplifyIfEquationAsserts1(eqns,condition,conditions,brancheqns1,BackendDAE.ALGORITHM(size,DAE.ALGORITHM_STMTS({DAE.STMT_ASSERT(e,msg,level,source1)}),source,crefExpand,eqAttr)::inEqns);
      then
        (beqns,eqns);

    case (BackendDAE.ALGORITHM(size=size,alg=DAE.ALGORITHM_STMTS({DAE.STMT_ASSERT(cond=cond,msg=msg,level=level,source=source1)}),source=source,expand=crefExpand,attr=eqAttr)::eqns,SOME(e),_,_,_)
      equation
        e = DAE.IFEXP(e,cond,DAE.BCONST(true));
        e = List.fold(conditions,makeIfExp,e);
        (beqns,eqns) = simplifyIfEquationAsserts1(eqns,condition,conditions,brancheqns1,BackendDAE.ALGORITHM(size,DAE.ALGORITHM_STMTS({DAE.STMT_ASSERT(e,msg,level,source1)}),source,crefExpand,eqAttr)::inEqns);
      then
        (beqns,eqns);

    case (BackendDAE.ALGORITHM(size=size,alg=DAE.ALGORITHM_STMTS({DAE.STMT_TERMINATE(msg=msg,source=source1)}),source=source,expand=crefExpand,attr=eqAttr)::eqns,NONE(),_,_,_)
      equation
        e = List.fold(conditions,makeIfExp,DAE.BCONST(true));
        (beqns,eqns) =  simplifyIfEquationAsserts1(eqns,condition,conditions,brancheqns1,BackendDAE.ALGORITHM(size,DAE.ALGORITHM_STMTS({DAE.STMT_IF(e,{DAE.STMT_TERMINATE(msg,source1)},DAE.NOELSE(),source1)}),source,crefExpand,eqAttr)::inEqns);
      then
        (beqns,eqns);

    case (BackendDAE.ALGORITHM(size=size,alg=DAE.ALGORITHM_STMTS({DAE.STMT_TERMINATE(msg=msg,source=source1)}),source=source,expand=crefExpand,attr=eqAttr)::eqns,SOME(e),_,_,_)
      equation
        e = List.fold(conditions,makeIfExp,e);
        (beqns,eqns) = simplifyIfEquationAsserts1(eqns,condition,conditions,brancheqns1,BackendDAE.ALGORITHM(size,DAE.ALGORITHM_STMTS({DAE.STMT_IF(e,{DAE.STMT_TERMINATE(msg,source1)},DAE.NOELSE(),source1)}),source,crefExpand,eqAttr)::inEqns);
      then
        (beqns,eqns);

    case (eqn::eqns,_,_,_,_)
      equation
        (beqns,eqns) = simplifyIfEquationAsserts1(eqns,condition,conditions,eqn::brancheqns1,inEqns);
      then
        (beqns,eqns);
  end match;
end simplifyIfEquationAsserts1;

protected function makeIfExp
  input DAE.Exp cond;
  input DAE.Exp else_;
  output DAE.Exp oExp;
algorithm
  oExp := DAE.IFEXP(cond,DAE.BCONST(true),else_);
end makeIfExp;

protected function countEquationsInBranches "
Checks that the number of equations is the same in all branches
of an if-equation"
  input list<list<BackendDAE.Equation>> trueBranches;
  input list<BackendDAE.Equation> falseBranch;
  input DAE.ElementSource source;
  output Integer nrOfEquations;
algorithm
  nrOfEquations := matchcontinue(trueBranches,falseBranch,source)
    local
      list<Boolean> b;
      list<String> strs;
      String str,eqstr;
      list<Integer> nrOfEquationsBranches;

    case (_, _, _)
      equation
        nrOfEquations = BackendEquation.equationLstSize(falseBranch);
        nrOfEquationsBranches = List.map(trueBranches, BackendEquation.equationLstSize);
        b = List.map1(nrOfEquationsBranches, intEq, nrOfEquations);
        true = List.reduce(b,boolAnd);
      then
        nrOfEquations;

    // An if-equation with non-parameter conditions must have an else-clause.
    case (_, {}, _)
      equation
        Error.addSourceMessage(Error.IF_EQUATION_MISSING_ELSE, {},
          DAEUtil.getElementSourceFileInfo(source));
      then
        fail();

    // If if-equation with non-parameter conditions must have the same number of
    // equations in each branch.
    case (_, _ :: _, _)
      equation
        nrOfEquations = BackendEquation.equationLstSize(falseBranch);
        nrOfEquationsBranches = List.map(trueBranches, BackendEquation.equationLstSize);
        eqstr = stringDelimitList(List.map(listAppend(trueBranches,{falseBranch}),BackendDump.dumpEqnsStr),"\n");
        strs = List.map(nrOfEquationsBranches, intString);
        str = stringDelimitList(strs,",");
        str = "{" + str + "," + intString(nrOfEquations) + "}";
        Error.addSourceMessage(Error.IF_EQUATION_UNBALANCED_2,{str,eqstr},DAEUtil.getElementSourceFileInfo(source));
      then
        fail();

  end matchcontinue;
end countEquationsInBranches;

protected function makeEquationLstToResidualExpLst
  input list<BackendDAE.Equation> eqLst;
  output list<DAE.Exp> oExpLst;
algorithm
  oExpLst := matchcontinue(eqLst)
    local
      list<BackendDAE.Equation> rest;
      list<DAE.Exp> exps1,exps2,exps;
      BackendDAE.Equation eq;
      DAE.ElementSource source;
      String str;
    case ({}) then {};
    case ((eq as BackendDAE.ALGORITHM(source = source))::rest)
      equation
        str = BackendDump.equationString(eq);
        str = Util.stringReplaceChar(str,"\n","");
        Error.addSourceMessage(Error.IF_EQUATION_WARNING,{str},DAEUtil.getElementSourceFileInfo(source));
        exps = makeEquationLstToResidualExpLst(rest);
      then exps;
    case (eq::rest)
      equation
        exps1 = makeEquationToResidualExpLst(eq);
        exps2 = makeEquationLstToResidualExpLst(rest);
        exps = listAppend(exps1,exps2);
      then
        exps;
  end matchcontinue;
end makeEquationLstToResidualExpLst;

protected function makeEquationToResidualExpLst "
If-equations with more than 1 equation in each branch cannot be transformed
to a single equation with residual if-expression. This function translates such
equations to a list of residual if-expressions. Normal equations are translated
to a list with a single residual expression."
  input BackendDAE.Equation eq;
  output list<DAE.Exp> oExpLst;
algorithm
  oExpLst := matchcontinue(eq)
    local
      list<list<BackendDAE.Equation>> tbs;
      list<BackendDAE.Equation> fbs;
      list<DAE.Exp> conds, fbsExp,exps;
      list<list<DAE.Exp>> tbsExp;
      BackendDAE.Equation elt;
      DAE.Exp exp;

    case (BackendDAE.IF_EQUATION(conditions=conds,eqnstrue=tbs,eqnsfalse=fbs))
      equation
        fbsExp = makeEquationLstToResidualExpLst(fbs);
        tbsExp = List.map(tbs, makeEquationLstToResidualExpLst);
        exps = makeResidualIfExpLst(conds,tbsExp,fbsExp);
      then
        exps;
    case (elt)
      equation
        exp=makeEquationToResidualExp(elt);
      then
        {exp};
  end matchcontinue;
end makeEquationToResidualExpLst;

protected function makeResidualIfExpLst
  input list<DAE.Exp> inExp1;
  input list<list<DAE.Exp>> inExpLst2;
  input list<DAE.Exp> inExpLst3;
  output list<DAE.Exp> outExpLst;
algorithm
  outExpLst := match (inExp1,inExpLst2,inExpLst3)
    local
      list<list<DAE.Exp>> tbs,tbsRest;
      list<DAE.Exp> tbsFirst,fbs,rest_res;
      list<DAE.Exp> conds;
      DAE.Exp ifexp,fb;

    case (_,tbs,{})
      equation
        List.map_0(tbs, List.assertIsEmpty);
      then {};

    case (conds,tbs,fb::fbs)
      equation
        tbsRest = List.map(tbs,List.rest);
        rest_res = makeResidualIfExpLst(conds, tbsRest, fbs);

        tbsFirst = List.map(tbs,List.first);

        ifexp = Expression.makeNestedIf(conds,tbsFirst,fb);
      then
        (ifexp :: rest_res);
  end match;
end makeResidualIfExpLst;

protected function makeEquationToResidualExp ""
  input BackendDAE.Equation eq;
  output DAE.Exp oExp;
algorithm
  oExp := matchcontinue(eq)
    local
      DAE.Exp e1,e2;
      DAE.ComponentRef cr1;
      String str;
      DAE.Type ty;
    // normal equation
    case(BackendDAE.EQUATION(exp=e1,scalar=e2))
      equation
        ty = Expression.typeof(e1);
        true = Types.isIntegerOrRealOrSubTypeOfEither(ty);
        oExp = Expression.expSub(e1,e2);
      then
        oExp;
    // equation from array TODO! check if this works!
    case(BackendDAE.ARRAY_EQUATION(left=e1,right=e2))
      equation
        oExp = Expression.expSub(e1,e2);
      then
        oExp;
    // solved equation
    case(BackendDAE.SOLVED_EQUATION(componentRef=cr1, exp=e2))
      equation
        e1 = Expression.crefExp(cr1);
        oExp = Expression.expSub(e1,e2);
      then
        oExp;
    // residual equation
    case(BackendDAE.RESIDUAL_EQUATION(exp = oExp))
      then
        oExp;
    // complex equation
    case(BackendDAE.COMPLEX_EQUATION(left = e1, right = e2))
      equation
        oExp = Expression.expSub(e1,e2);
      then
        oExp;
    // failure
    case _
      equation
        str = "- BackendDAEOptimize.makeEquationToResidualExp failed to transform equation: " + BackendDump.equationString(eq) + " to residual form!";
        Error.addMessage(Error.INTERNAL_ERROR, {str});
      then fail();
  end matchcontinue;
end makeEquationToResidualExp;

protected function makeEquationsFromResiduals
  input list<DAE.Exp> inExp1 "conds";
  input list<list<DAE.Exp>> inExpLst2 "tbs";
  input list<DAE.Exp> inExpLst3;
  input DAE.ElementSource inSource "the origin of the element";
  input BackendDAE.EquationAttributes inEqAttr;
  output list<BackendDAE.Equation> outExpLst;
algorithm
  outExpLst := match (inExp1, inExpLst2, inExpLst3, inSource, inEqAttr)
    local
      list<list<DAE.Exp>> tbsRest;
      list<DAE.Exp> tbsFirst, fbs;
      DAE.Exp ifexp, fb;
      BackendDAE.Equation eq;
      list<BackendDAE.Equation> rest_res;

    case (_, _, {}, _, _)
      equation
        List.map_0(inExpLst2, List.assertIsEmpty);
      then {};

    case (_, _, fb::fbs, _, _)
      equation
        tbsRest = List.map(inExpLst2, List.rest);
        rest_res = makeEquationsFromResiduals(inExp1, tbsRest, fbs, inSource, inEqAttr);

        tbsFirst = List.map(inExpLst2, List.first);

        ifexp = Expression.makeNestedIf(inExp1,tbsFirst,fb);
        eq = BackendDAE.EQUATION(DAE.RCONST(0.0), ifexp, inSource, inEqAttr);
      then (eq::rest_res);
  end match;
end makeEquationsFromResiduals;


// =============================================================================
// simplify semiLinear calls
//
// =============================================================================

public function simplifysemiLinear "author: Frenkel TUD 2012-08
  This function traveres all equations and tries to simplify calls to semiLinear"
  input BackendDAE.BackendDAE dae;
  output BackendDAE.BackendDAE odae;
algorithm
  odae := BackendDAEUtil.mapEqSystem(dae,simplifysemiLinearWork);
end simplifysemiLinear;

protected function simplifysemiLinearWork "author: Frenkel TUD 2012-08
  This function traveres all equations and tries to simplify calls to semiLinear"
  input BackendDAE.EqSystem isyst;
  input BackendDAE.Shared ishared;
  output BackendDAE.EqSystem osyst;
  output BackendDAE.Shared oshared;
algorithm
  (osyst,oshared) := matchcontinue (isyst,ishared)
    local
      BackendDAE.Variables vars;
      BackendDAE.EquationArray eqns;
      list<tuple<BackendDAE.Equation,Integer>> eqnslst;
      BackendDAE.EqSystem syst;
      BackendDAE.Shared shared;
      HashTableExpToIndex.HashTable ht;
      array<list<tuple<BackendDAE.Equation,Integer>>> eqnsarray;
      BackendDAE.StateSets stateSets;
      BackendDAE.BaseClockPartitionKind partitionKind;

    case (BackendDAE.EQSYSTEM(orderedVars=vars,orderedEqs=eqns,stateSets=stateSets,partitionKind=partitionKind),shared)
      equation
        // traverse the equations and collect all semiLinear calls  y=semiLinear(x,sa,sb)
        (eqns,(eqnslst,_,true)) = BackendEquation.traverseBackendDAEEqnsWithUpdate(eqns,simplifysemiLinearFinder,({},0,false));
        // sort for (y,x) pairs
        eqnsarray = arrayCreate(5,{});
        ht = HashTableExpToIndex.emptyHashTable();
        eqnsarray = semiLinearSort(eqnslst,ht,1,eqnsarray);
        eqnsarray = semiLinearSort1(arrayList(eqnsarray),1,arrayCreate(5,{}));
        // optimize
        // y = semiLinear(x,sa,s1)
        // y = semiLinear(x,s1,s2)
        // y = semiLinear(x,s2,s3)
        // ...
        // y = semiLinear(x,sn,sb)
        // ->
        // s1 = if (x>=0) then sa else sb
        // s2 = s1
        // s3 = s2
        // ..
        // sn = sn-1
        // y = semiLinear(x,sa,sb)
        eqnslst = List.fold(arrayList(eqnsarray),semiLinearOptimize,{});
        // replace the equations in the system
        eqns = List.fold(eqnslst,semiLinearReplaceEqns,eqns);
        syst = BackendDAE.EQSYSTEM(vars,eqns,NONE(),NONE(),BackendDAE.NO_MATCHING(),stateSets,partitionKind);
      then (syst,shared);
    case (_,_)
      then (isyst,ishared);
  end matchcontinue;
end simplifysemiLinearWork;

protected function semiLinearReplaceEqns "author: Frenkel TUD 2012-08
  helper for simplifysemiLinear"
  input tuple<BackendDAE.Equation, Integer /*zero-based*/> iTpl;
  input BackendDAE.EquationArray iEqns;
  output BackendDAE.EquationArray oEqns;
protected
  BackendDAE.Equation eqn;
  Integer index;
algorithm
  (eqn, index) := iTpl;
  if Flags.isSet(Flags.SEMILINEAR) then
    BackendDump.debugStrEqnStr("Replace with ", eqn, "\n");
  end if;
  oEqns := BackendEquation.setAtIndex(iEqns, index+1, eqn);
end semiLinearReplaceEqns;

protected function semiLinearOptimize
"author: Frenkel TUD 2012-08
  helper for simplifysemiLinear"
  input list<tuple<BackendDAE.Equation,Integer>> eqnslst;
  input list<tuple<BackendDAE.Equation,Integer>> iAcc;
  output list<tuple<BackendDAE.Equation,Integer>> oAcc;
algorithm
  oAcc := matchcontinue(eqnslst,iAcc)
    local
      HashTableExpToIndex.HashTable ht,ht1;
      array<tuple<BackendDAE.Equation,Integer>> eqnsarray;
      list<DAE.Exp> explst;
    case (_::{},_) then iAcc;
    case (_,_)
      equation
        // get HashMab sa-> index
        ht = HashTableExpToIndex.emptyHashTable();
        ht1 = HashTableExpToIndex.emptyHashTable();
        (ht,ht1) = semiLinearOptimize1(eqnslst,1,ht,ht1);
        // get sa
        explst = List.fold1(BaseHashTable.hashTableKeyList(ht),semiLinearGetSA,ht1,{});
        eqnsarray = listArray(eqnslst);
        // optimize
      then
        semiLinearOptimize2(explst,ht,eqnsarray,iAcc);
    case(_,_) then iAcc;
  end matchcontinue;
end semiLinearOptimize;

protected function semiLinearOptimize2
"author: Frenkel TUD 2012-08
  helper for simplifysemiLinear"
  input list<DAE.Exp> saLst;
  input HashTableExpToIndex.HashTable iHt;
  input array<tuple<BackendDAE.Equation,Integer>> IEqnsarray;
  input list<tuple<BackendDAE.Equation,Integer>> iAcc;
  output list<tuple<BackendDAE.Equation,Integer>> oAcc;
algorithm
  oAcc := matchcontinue(saLst,iHt,IEqnsarray,iAcc)
    local
      DAE.Exp sa,sb,s1,y,x;
      list<DAE.Exp> rest;
      list<tuple<DAE.Exp,Integer,DAE.ElementSource>> explst;
      list<tuple<BackendDAE.Equation,Integer>> acc;
      BackendDAE.Equation eqn,eqn1;
      Integer i1,index,index1;
      Absyn.Path path;
      DAE.CallAttributes attr;
      DAE.ElementSource source,source1;
      BackendDAE.EquationAttributes eqAttr;
    case ({},_,_,_) then iAcc;
    case (sa::rest,_,_,_)
      equation
        i1 = BaseHashTable.get(sa,iHt);
        ((BackendDAE.EQUATION(exp=y,scalar=DAE.CALL(path=path,expLst = {x,_,s1},attr=attr),source=source,attr=eqAttr),index)) = IEqnsarray[i1];
        // get Order of s1,s2,s3,..,sn,sb
        (sb,source1,index1,explst) = semiLinearOptimize3(s1,source,index,iHt,IEqnsarray,{});
        // generate optimized equations
        // s1 = if (x>=0) then sa else sb
        // s2 = s1
        // ..
        // sn = sn-1
        // y = semiLinear(x,sa,sb)
        eqn = BackendDAE.EQUATION(s1,DAE.IFEXP(DAE.CALL(Absyn.IDENT("noEvent"),{DAE.RELATION(x,DAE.GREATEREQ(DAE.T_REAL_DEFAULT),DAE.RCONST(0.0),-1,NONE())},DAE.callAttrBuiltinBool),sa,sb),source,eqAttr);
        eqn1 = BackendDAE.EQUATION(y,DAE.CALL(path,{x,sa,sb},attr),source1,eqAttr);
        acc = semiLinearOptimize4(explst,(eqn1,index1)::iAcc, eqAttr);
      then
        semiLinearOptimize2(rest,iHt,IEqnsarray,(eqn,index)::acc);
    case (_::rest,_,_,_)
      then
        semiLinearOptimize2(rest,iHt,IEqnsarray,iAcc);
  end matchcontinue;
end semiLinearOptimize2;

protected function semiLinearOptimize4
"author: Frenkel TUD 2012-08
  helper for simplifysemiLinear"
  input list<tuple<DAE.Exp,Integer,DAE.ElementSource>> explst;
  input list<tuple<BackendDAE.Equation,Integer>> iAcc;
  input BackendDAE.EquationAttributes inEqAttr;
  output list<tuple<BackendDAE.Equation,Integer>> oAcc;
algorithm
  oAcc := match(explst, iAcc, inEqAttr)
    local
      DAE.Exp s1,s2;
      list<tuple<DAE.Exp,Integer,DAE.ElementSource>> rest;
      Integer index;
      BackendDAE.Equation eqn;
      DAE.ElementSource source;
    case ({}, _, _) then iAcc;
    case (_::{}, _, _) then iAcc;
    case((s2,index,source)::(rest as ((s1,_,_)::_)), _, _)
      equation
        eqn = BackendDAE.EQUATION(s2, s1, source, inEqAttr);
      then
        semiLinearOptimize4(rest, (eqn, index)::iAcc, inEqAttr);
  end match;
end semiLinearOptimize4;

protected function semiLinearOptimize3
"author: Frenkel TUD 2012-08
  helper for simplifysemiLinear"
  input DAE.Exp exp;
  input DAE.ElementSource isource;
  input Integer iIndex;
  input HashTableExpToIndex.HashTable iHt;
  input array<tuple<BackendDAE.Equation,Integer>> IEqnsarray;
  input list<tuple<DAE.Exp,Integer,DAE.ElementSource>> iAcc;
  output DAE.Exp slast;
  output DAE.ElementSource osource;
  output Integer oIndex;
  output list<tuple<DAE.Exp,Integer,DAE.ElementSource>> oAcc;
algorithm
  (slast,osource,oIndex,oAcc) := matchcontinue(exp,isource,iIndex,iHt,IEqnsarray,iAcc)
    local
      DAE.Exp sb;
      Integer i,index;
      DAE.ElementSource source;
    case(_,_,_,_,_,_)
      equation
        i = BaseHashTable.get(exp,iHt);
        ((BackendDAE.EQUATION(scalar=DAE.CALL(expLst = {_,_,sb}),source=source),index)) = IEqnsarray[i];
        (sb,source,index,oAcc) = semiLinearOptimize3(sb,source,index,iHt,IEqnsarray,(exp,iIndex,source)::iAcc);
      then
        (sb,source,index,oAcc);
    case(_,_,_,_,_,_)
      then
        (exp,isource,iIndex,iAcc);
  end matchcontinue;
end semiLinearOptimize3;

protected function semiLinearGetSA
"author: Frenkel TUD 2012-08
  helper for simplifysemiLinear"
  input DAE.Exp key;
  input HashTableExpToIndex.HashTable iHt1;
  input list<DAE.Exp> iAcc;
  output list<DAE.Exp> oAcc;
algorithm
  oAcc := matchcontinue(key,iHt1,iAcc)
    case (_,_,_)
      equation
        _ = BaseHashTable.get(key,iHt1);
      then
        iAcc;
    case(_,_,_)
      then
        key::iAcc;
  end matchcontinue;
end semiLinearGetSA;

protected function semiLinearOptimize1
"author: Frenkel TUD 2012-08
  helper for simplifysemiLinear"
  input list<tuple<BackendDAE.Equation,Integer>> eqnslst;
  input Integer i;
  input HashTableExpToIndex.HashTable iHt;
  input HashTableExpToIndex.HashTable iHt1;
  output HashTableExpToIndex.HashTable oHt;
  output HashTableExpToIndex.HashTable oHt1;
algorithm
  (oHt,oHt1) := match(eqnslst,i,iHt,iHt1)
    local
     BackendDAE.Equation eqn;
      list<tuple<BackendDAE.Equation,Integer>> rest;
      HashTableExpToIndex.HashTable ht,ht1;
      DAE.Exp sa,sb;
    case ({},_,_,_) then (iHt,iHt1);
    case ((BackendDAE.EQUATION(scalar=DAE.CALL(expLst = {_,sa,sb})),_)::rest,_,_,_)
      equation
        ht = BaseHashTable.add((sa,i), iHt);
        ht1 = BaseHashTable.add((sb,i), iHt1);
        (ht,ht1) = semiLinearOptimize1(rest,i+1,ht,ht1);
      then
        (ht,ht1);
  end match;
end semiLinearOptimize1;

protected function semiLinearSort "author: Frenkel TUD 2012-08
  helper for simplifysemiLinear"
  input  list<tuple<BackendDAE.Equation,Integer>> eqnslst;
  input  HashTableExpToIndex.HashTable iHt;
  input  Integer size;
  input  array<list<tuple<BackendDAE.Equation,Integer>>> iEqnsarray;
  output  array<list<tuple<BackendDAE.Equation,Integer>>> oEqnsarray;
algorithm
  oEqnsarray := matchcontinue(eqnslst,iHt,size,iEqnsarray)
    local
     BackendDAE.Equation eqn;
     Integer index,i;
     list<tuple<BackendDAE.Equation,Integer>> rest,eqns;
     HashTableExpToIndex.HashTable ht;
     DAE.Exp y;
     array<list<tuple<BackendDAE.Equation,Integer>>> eqnsarray;
    case ({},_,_,_) then iEqnsarray;
    case ((eqn as BackendDAE.EQUATION(exp=y),index)::rest,_,_,_)
      equation
        i = BaseHashTable.get(y,iHt);
        eqns = iEqnsarray[i];
        eqnsarray = arrayUpdate(iEqnsarray,i,(eqn,index)::eqns);
      then
        semiLinearSort(rest,iHt,size,eqnsarray);
    case ((eqn as BackendDAE.EQUATION(exp=y),index)::rest,_,_,_)
      equation
        ht = BaseHashTable.add((y,size), iHt);
        // expand if necesarray
        eqnsarray = if intGt(size,arrayLength(iEqnsarray)) then Array.expand(5, iEqnsarray, {}) else iEqnsarray;
        eqnsarray = arrayUpdate(eqnsarray,size,{(eqn,index)});
      then
        semiLinearSort(rest,ht,size+1,eqnsarray);
  end matchcontinue;
end semiLinearSort;

protected function semiLinearSort1
"author: Frenkel TUD 2012-08
  helper for simplifysemiLinear"
  input  list<list<tuple<BackendDAE.Equation,Integer>>> eqnslstlst;
  input  Integer size;
  input  array<list<tuple<BackendDAE.Equation,Integer>>> iEqnsarray;
  output  array<list<tuple<BackendDAE.Equation,Integer>>> oEqnsarray;
algorithm
  oEqnsarray := match(eqnslstlst,size,iEqnsarray)
    local
     Integer size1;
     tuple<BackendDAE.Equation,Integer> tpl;
     list<tuple<BackendDAE.Equation,Integer>> eqns;
     list<list<tuple<BackendDAE.Equation,Integer>>> rest;
     HashTableExpToIndex.HashTable ht;
     array<list<tuple<BackendDAE.Equation,Integer>>> eqnsarray;
    case ({},_,_) then iEqnsarray;
    case ((tpl::{})::rest,_,_)
      equation
        // expand if necesarray
        eqnsarray = if intGt(size,arrayLength(iEqnsarray)) then Array.expand(5, iEqnsarray, {}) else iEqnsarray;
        eqnsarray = arrayUpdate(eqnsarray,size,{tpl});
      then
        semiLinearSort1(rest,size+1,eqnsarray);
    case (eqns::rest,_,_)
      equation
        ht = HashTableExpToIndex.emptyHashTable();
        (size1,eqnsarray) = semiLinearSort2(eqns,ht,size,iEqnsarray);
      then
        semiLinearSort1(rest,size1,eqnsarray);
  end match;
end semiLinearSort1;

protected function semiLinearSort2
"author: Frenkel TUD 2012-08
  helper for simplifysemiLinear"
  input  list<tuple<BackendDAE.Equation,Integer>> eqnslst;
  input  HashTableExpToIndex.HashTable iHt;
  input  Integer size;
  input  array<list<tuple<BackendDAE.Equation,Integer>>> iEqnsarray;
  output  Integer osize;
  output  array<list<tuple<BackendDAE.Equation,Integer>>> oEqnsarray;
algorithm
  (osize,oEqnsarray) := matchcontinue(eqnslst,iHt,size,iEqnsarray)
    local
     BackendDAE.Equation eqn;
     Integer index,i;
     list<tuple<BackendDAE.Equation,Integer>> rest,eqns;
     HashTableExpToIndex.HashTable ht;
     DAE.Exp x;
     array<list<tuple<BackendDAE.Equation,Integer>>> eqnsarray;
    case ({},_,_,_) then (size,iEqnsarray);
    case ((eqn as BackendDAE.EQUATION(scalar=DAE.CALL(expLst = x::_)),index)::rest,_,_,_)
      equation
        i = BaseHashTable.get(x,iHt);
        eqns = iEqnsarray[i];
        eqnsarray = arrayUpdate(iEqnsarray,i,(eqn,index)::eqns);
        (i,eqnsarray) = semiLinearSort2(rest,iHt,size,eqnsarray);
      then
        (i,eqnsarray);
    case ((eqn as BackendDAE.EQUATION(scalar=DAE.CALL(expLst = x::_)),index)::rest,_,_,_)
      equation
        ht = BaseHashTable.add((x,size), iHt);
        // expand if necesarray
        eqnsarray = if intGt(size,arrayLength(iEqnsarray)) then Array.expand(5, iEqnsarray, {}) else iEqnsarray;
        eqnsarray = arrayUpdate(eqnsarray,size,{(eqn,index)});
        (i,eqnsarray) = semiLinearSort2(rest,ht,size+1,eqnsarray);
      then
        (i,eqnsarray);
  end matchcontinue;
end semiLinearSort2;

protected function simplifysemiLinearFinder
"helper for simplifysemiLinear"
  input BackendDAE.Equation inEq;
  input tuple<list<tuple<BackendDAE.Equation,Integer>>,Integer,Boolean> inTpl;
  output BackendDAE.Equation outEq;
  output tuple<list<tuple<BackendDAE.Equation,Integer>>,Integer,Boolean> outTpl;
algorithm
  (outEq,outTpl) := matchcontinue (inEq,inTpl)
    local
      BackendDAE.Equation eqn;
      list<tuple<BackendDAE.Equation,Integer>> eqnslst;
      Integer index;
      Boolean b;
      DAE.Exp x,y,sa,sb;
      DAE.ElementSource source;
      Absyn.Path path;
      DAE.CallAttributes attr;
      BackendDAE.EquationAttributes eqAttr;

    // 0 = semiLinear(0,sa,sb) -> sa=sb
    case (BackendDAE.EQUATION(exp=y,scalar=DAE.CALL(path=Absyn.IDENT("semiLinear"),expLst={x,sa,sb}),source=source,attr=eqAttr),(eqnslst,index,_))
      equation
        true = Expression.isZero(y);
        true = Expression.isZero(x);
      then (BackendDAE.EQUATION(sa,sb,source,eqAttr),(eqnslst,index+1,true));
    case (BackendDAE.EQUATION(exp=DAE.CALL(path=Absyn.IDENT("semiLinear"),expLst={x,sa,sb}),scalar=y,source=source,attr=eqAttr),(eqnslst,index,_))
      equation
        true = Expression.isZero(y);
        true = Expression.isZero(x);
      then (BackendDAE.EQUATION(sa,sb,source,eqAttr),(eqnslst,index+1,true));
    case (BackendDAE.EQUATION(exp=y,scalar=DAE.UNARY(exp=DAE.CALL(path=Absyn.IDENT("semiLinear"),expLst={x,sa,sb})),source=source,attr=eqAttr),(eqnslst,index,_))
      equation
        true = Expression.isZero(y);
        true = Expression.isZero(x);
      then (BackendDAE.EQUATION(sa,sb,source,eqAttr),(eqnslst,index+1,true));
    case (BackendDAE.EQUATION(exp=DAE.UNARY(exp=DAE.CALL(path=Absyn.IDENT("semiLinear"),expLst={x,sa,sb})),scalar=y,source=source,attr=eqAttr),(eqnslst,index,_))
      equation
        true = Expression.isZero(y);
        true = Expression.isZero(x);
      then (BackendDAE.EQUATION(sa,sb,source,eqAttr),(eqnslst,index+1,true));
    // y = -semiLinear(-x,sb,sa) -> y = semiLinear(x,sa,sb)
    case (BackendDAE.EQUATION(exp=y,scalar=DAE.UNARY(exp=DAE.CALL(path=path as Absyn.IDENT("semiLinear"),expLst={DAE.UNARY(exp=x),sb,sa},attr=attr)),source=source,attr=eqAttr),(eqnslst,index,_))
      equation
        eqn = BackendDAE.EQUATION(y,DAE.CALL(path,{x,sa,sb},attr),source,eqAttr);
        if Flags.isSet(Flags.SEMILINEAR) then
          BackendDump.debugStrEqnStr("Found semiLinear ",eqn,"\n");
        end if;
      then (eqn,((eqn,index)::eqnslst,index+1,true));
    case (BackendDAE.EQUATION(exp=DAE.UNARY(exp=DAE.CALL(path=path as Absyn.IDENT("semiLinear"),expLst={DAE.UNARY(exp=x),sb,sa},attr=attr)),scalar=y,source=source,attr=eqAttr),(eqnslst,index,_))
      equation
        eqn = BackendDAE.EQUATION(y,DAE.CALL(path,{x,sa,sb},attr),source,eqAttr);
        if Flags.isSet(Flags.SEMILINEAR) then
          BackendDump.debugStrEqnStr("Found semiLinear ",eqn,"\n");
        end if;
      then (eqn,((eqn,index)::eqnslst,index+1,true));
    // -y = semiLinear(-x,sb,sa) -> y = semiLinear(x,sa,sb)
    case (BackendDAE.EQUATION(exp=DAE.UNARY(exp=y),scalar=DAE.CALL(path = path as Absyn.IDENT("semiLinear"), expLst = {DAE.UNARY(exp=x),sb,sa},attr=attr),source=source,attr=eqAttr),(eqnslst,index,_))
      equation
        eqn = BackendDAE.EQUATION(y,DAE.CALL(path,{x,sa,sb},attr),source,eqAttr);
        if Flags.isSet(Flags.SEMILINEAR) then
          BackendDump.debugStrEqnStr("Found semiLinear ",eqn,"\n");
        end if;
      then (eqn,((eqn,index)::eqnslst,index+1,true));
    case (BackendDAE.EQUATION(exp=DAE.CALL(path = path as Absyn.IDENT("semiLinear"), expLst = {DAE.UNARY(exp=x),sb,sa},attr=attr),scalar=DAE.UNARY(exp=y),source=source,attr=eqAttr),(eqnslst,index,_))
      equation
        eqn = BackendDAE.EQUATION(y,DAE.CALL(path,{x,sa,sb},attr),source,eqAttr);
        if Flags.isSet(Flags.SEMILINEAR) then
          BackendDump.debugStrEqnStr("Found semiLinear ",eqn,"\n");
        end if;
      then (eqn,((eqn,index)::eqnslst,index+1,true));
    // y = semiLinear(-x,sb,sa) -> -y = semiLinear(x,sa,sb)
    case (BackendDAE.EQUATION(exp=y,scalar=DAE.CALL(path = path as Absyn.IDENT("semiLinear"), expLst = {DAE.UNARY(exp=x),sb,sa},attr=attr),source=source,attr=eqAttr),(eqnslst,index,_))
      equation
        y = Expression.negate(y);
        eqn = BackendDAE.EQUATION(y,DAE.CALL(path,{x,sa,sb},attr),source,eqAttr);
        if Flags.isSet(Flags.SEMILINEAR) then
          BackendDump.debugStrEqnStr("Found semiLinear ",eqn,"\n");
        end if;
      then (eqn,((eqn,index)::eqnslst,index+1,true));
    case (BackendDAE.EQUATION(exp=DAE.CALL(path = path as Absyn.IDENT("semiLinear"), expLst = {DAE.UNARY(exp=x),sb,sa},attr=attr),scalar=y,source=source,attr=eqAttr),(eqnslst,index,_))
      equation
        y = Expression.negate(y);
        eqn = BackendDAE.EQUATION(y,DAE.CALL(path,{x,sa,sb},attr),source,eqAttr);
        if Flags.isSet(Flags.SEMILINEAR) then
          BackendDump.debugStrEqnStr("Found semiLinear ",eqn,"\n");
        end if;
      then (eqn,((eqn,index)::eqnslst,index+1,true));
    // y = semiLinear(x,sa,sb)
    case (eqn as BackendDAE.EQUATION(scalar=DAE.CALL(path =Absyn.IDENT("semiLinear"))),(eqnslst,index,_))
      equation
        if Flags.isSet(Flags.SEMILINEAR) then
          BackendDump.debugStrEqnStr("Found semiLinear ",eqn,"\n");
        end if;
      then (eqn,((eqn,index)::eqnslst,index+1,true));
    case (eqn as BackendDAE.EQUATION(exp=DAE.CALL(path =Absyn.IDENT("semiLinear"))),(eqnslst,index,_))
      equation
        if Flags.isSet(Flags.SEMILINEAR) then
          BackendDump.debugStrEqnStr("Found semiLinear ",eqn,"\n");
        end if;
      then (eqn,((eqn,index)::eqnslst,index+1,true));
    case (BackendDAE.EQUATION(exp=y,scalar=DAE.UNARY(exp= x as DAE.CALL(path = Absyn.IDENT("semiLinear"))),source=source,attr=eqAttr),(eqnslst,index,_))
      equation
        y = Expression.negate(y);
        eqn = BackendDAE.EQUATION(y,x,source,eqAttr);
        if Flags.isSet(Flags.SEMILINEAR) then
          BackendDump.debugStrEqnStr("Found semiLinear ",eqn,"\n");
        end if;
      then (eqn,((eqn,index)::eqnslst,index+1,true));
    case (BackendDAE.EQUATION(exp=DAE.UNARY(exp= x as DAE.CALL(path = Absyn.IDENT("semiLinear"))),scalar=y,source=source,attr=eqAttr),(eqnslst,index,_))
      equation
        y = Expression.negate(y);
        eqn = BackendDAE.EQUATION(y,x,source,eqAttr);
        if Flags.isSet(Flags.SEMILINEAR) then
          BackendDump.debugStrEqnStr("Found semiLinear ",eqn,"\n");
        end if;
      then (eqn,((eqn,index)::eqnslst,index+1,true));

    case (eqn,(eqnslst,index,b)) then (eqn,(eqnslst,index+1,b));
  end matchcontinue;
end simplifysemiLinearFinder;

// =============================================================================
// remove constants stuff
//
// =============================================================================

public function removeConstants "author: Frenkel TUD"
  input BackendDAE.BackendDAE inDAE;
  output BackendDAE.BackendDAE outDAE;
protected
  DAE.FunctionTree funcs;
  BackendDAE.Variables knvars, exobj, av;
  BackendDAE.EquationArray inieqns, remeqns;
  list<DAE.Constraint> constrs;
  list<DAE.ClassAttributes> clsAttrs;
  FCore.Cache cache;
  FCore.Graph graph;
  BackendDAE.EventInfo einfo;
  BackendDAE.ExternalObjectClasses eoc;
  BackendDAE.SymbolicJacobians symjacs;
  BackendVarTransform.VariableReplacements repl;
  BackendDAE.BackendDAEType btp;
  BackendDAE.EqSystems systs;
  list<BackendDAE.Equation> lsteqns;
  Boolean b;
  BackendDAE.ExtraInfo ei;
algorithm
  BackendDAE.DAE(systs, BackendDAE.SHARED(knvars, exobj, av, inieqns, remeqns, constrs, clsAttrs, cache, graph, funcs, einfo, eoc, btp, symjacs, ei)) := inDAE;
  repl := BackendVarTransform.emptyReplacements();
  repl := BackendVariable.traverseBackendDAEVars(knvars, removeConstantsFinder, repl);
  if Flags.isSet(Flags.DUMP_CONST_REPL) then
    BackendVarTransform.dumpReplacements(repl);
  end if;
  (knvars, (repl, _)) := BackendVariable.traverseBackendDAEVarsWithUpdate(knvars, replaceFinalVarTraverser, (repl, 0));
  lsteqns := BackendEquation.equationList(remeqns);
  (lsteqns, b) := BackendVarTransform.replaceEquations(lsteqns, repl, NONE());
  remeqns := if b then BackendEquation.listEquation(lsteqns) else remeqns;
  lsteqns := BackendEquation.equationList(inieqns);
  (lsteqns, b) := BackendVarTransform.replaceEquations(lsteqns, repl, NONE());
  inieqns := if b then BackendEquation.listEquation(lsteqns) else inieqns;
  systs := List.map1(systs, removeConstantsWork, repl);
  outDAE := BackendDAE.DAE(systs, BackendDAE.SHARED(knvars, exobj, av, inieqns, remeqns, constrs, clsAttrs, cache, graph, funcs, einfo, eoc, btp, symjacs, ei));
end removeConstants;

protected function removeConstantsWork "author: Frenkel TUD"
  input BackendDAE.EqSystem inEqSystem;
  input BackendVarTransform.VariableReplacements repl;
  output BackendDAE.EqSystem outEqSystem;
protected
  BackendDAE.Variables vars;
  BackendDAE.EquationArray eqns, eqns1;
  list<BackendDAE.Equation> eqns_1, lsteqns;
  Boolean b;
  BackendDAE.StateSets stateSets;
  BackendDAE.BaseClockPartitionKind partitionKind;
algorithm
  BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns, stateSets=stateSets, partitionKind=partitionKind) := inEqSystem;
  (vars, _) := BackendVariable.traverseBackendDAEVarsWithUpdate(vars, replaceFinalVarTraverser, (repl, 0));
  lsteqns := BackendEquation.equationList(eqns);
  (eqns_1, b) := BackendVarTransform.replaceEquations(lsteqns, repl, NONE());
  eqns1 := if b then BackendEquation.listEquation(eqns_1) else eqns;
  outEqSystem := if b then BackendDAE.EQSYSTEM(vars, eqns1, NONE(), NONE(), BackendDAE.NO_MATCHING(), stateSets, partitionKind) else inEqSystem;
end removeConstantsWork;

protected function removeConstantsFinder
  input BackendDAE.Var inVar;
  input BackendVarTransform.VariableReplacements inRepl;
  output BackendDAE.Var outVar;
  output BackendVarTransform.VariableReplacements outRepl;
algorithm
  (outVar,outRepl) := matchcontinue (inVar,inRepl)
    local
      BackendDAE.Var v;
      BackendVarTransform.VariableReplacements repl, repl_1;
      DAE.ComponentRef varName;
      DAE.Exp exp;

    case (v as BackendDAE.VAR(varName=varName, varKind=BackendDAE.CONST(), bindExp=SOME(exp)), repl)
      equation
        repl_1 = BackendVarTransform.addReplacement(repl, varName, exp, NONE());
      then (v, repl_1);

    else (inVar,inRepl);
  end matchcontinue;
end removeConstantsFinder;


// =============================================================================
// reaplace edge and change with (b and not pre(b)) and (v <> pre(v)
//
// =============================================================================

public function replaceEdgeChange "author: Frenkel TUD 2012-11
  edge(b) = b and not pre(b)
  change(b) = v <> pre(v)"
  input BackendDAE.BackendDAE inDAE;
  output BackendDAE.BackendDAE outDAE;
algorithm
  (outDAE,_) := BackendDAEUtil.mapEqSystemAndFold(inDAE, replaceEdgeChange0, false);
  outDAE := replaceEdgeChangeShared(outDAE);
end replaceEdgeChange;

protected function replaceEdgeChange0 "author: Frenkel TUD 2012-11"
  input BackendDAE.EqSystem isyst;
  input tuple<BackendDAE.Shared, Boolean> sharedChanged;
  output BackendDAE.EqSystem osyst;
  output tuple<BackendDAE.Shared, Boolean> osharedChanged;
algorithm
  (osyst, osharedChanged) := matchcontinue (isyst, sharedChanged)
    local
      BackendDAE.Variables orderedVars;
      BackendDAE.EquationArray orderedEqs;
      Option<BackendDAE.IncidenceMatrix> m;
      Option<BackendDAE.IncidenceMatrixT> mT;
      BackendDAE.Matching matching;
      BackendDAE.Shared shared;
      BackendDAE.StateSets stateSets;
      BackendDAE.BaseClockPartitionKind partitionKind;

    case (BackendDAE.EQSYSTEM(orderedVars, orderedEqs, m, mT, matching, stateSets, partitionKind), (shared, _)) equation
      _ = BackendDAEUtil.traverseBackendDAEExpsEqnsWithUpdate(orderedEqs, traverserreplaceEdgeChange, false);
    then (BackendDAE.EQSYSTEM(orderedVars, orderedEqs, m, mT, matching, stateSets, partitionKind), (shared, true));

    else (isyst, sharedChanged);
  end matchcontinue;
end replaceEdgeChange0;

protected function traverserreplaceEdgeChange "author: Frenkel TUD 2012-11"
  input DAE.Exp e;
  input Boolean b;
  output DAE.Exp oe;
  output Boolean ob;
algorithm
  (oe,ob) := Expression.traverseExp(e,traverserExpreplaceEdgeChange,b);
end traverserreplaceEdgeChange;

protected function traverserExpreplaceEdgeChange "author: Frenkel TUD 2012-11"
  input DAE.Exp inExp;
  input Boolean inB;
  output DAE.Exp outExp;
  output Boolean outB;
algorithm
  (outExp,outB) := matchcontinue (inExp,inB)
    local
      DAE.Exp e;
      DAE.Type ty;

    // change(v) -> v <> pre(v)
    case (DAE.CALL(path=Absyn.IDENT(name = "change"), expLst={e}), _)
      equation
        ty = Expression.typeof(e);
      then (DAE.RELATION(e, DAE.NEQUAL(ty), DAE.CALL(Absyn.IDENT("pre"), {e}, DAE.CALL_ATTR(ty, false, true, false, false, DAE.NO_INLINE(), DAE.NO_TAIL())), -1, NONE()), true);

    // edge(b) = b and not pre(b)
    case (DAE.CALL(path=Absyn.IDENT(name = "edge"), expLst={e}), _)
      equation
        ty = Expression.typeof(e);
      then (DAE.LBINARY(e, DAE.AND(ty), DAE.LUNARY(DAE.NOT(ty), DAE.CALL(Absyn.IDENT("pre"), {e}, DAE.CALL_ATTR(ty, false, true, false, false, DAE.NO_INLINE(), DAE.NO_TAIL())))), true);

    else (inExp,inB);
  end matchcontinue;
end traverserExpreplaceEdgeChange;

protected function replaceEdgeChangeShared "author: Frenkel TUD 2012-11"
  input BackendDAE.BackendDAE inDAE;
  output BackendDAE.BackendDAE outDAE;
protected
  BackendDAE.Variables knvars, exobj, aliasVars;
  BackendDAE.EquationArray remeqns, inieqns;
  list<DAE.Constraint> constrs;
  list<DAE.ClassAttributes> clsAttrs;
  FCore.Cache cache;
  FCore.Graph graph;
  DAE.FunctionTree funcTree;
  BackendDAE.ExternalObjectClasses eoc;
  BackendDAE.SymbolicJacobians symjacs;
  BackendDAE.EventInfo eventInfo;
  BackendDAE.BackendDAEType btp;
  BackendDAE.EqSystems systs;
  BackendDAE.ExtraInfo ei;
algorithm
  BackendDAE.DAE(systs, BackendDAE.SHARED(knvars, exobj, aliasVars, inieqns, remeqns, constrs, clsAttrs, cache, graph, funcTree, eventInfo, eoc, btp, symjacs, ei)) := inDAE;
  _ := BackendDAEUtil.traverseBackendDAEExpsEqnsWithUpdate(remeqns, traverserreplaceEdgeChange, false);
  outDAE := BackendDAE.DAE(systs, BackendDAE.SHARED(knvars, exobj, aliasVars, inieqns, remeqns, constrs, clsAttrs, cache, graph, funcTree, eventInfo, eoc, btp, symjacs, ei));
end replaceEdgeChangeShared;

// =============================================================================
// section for postOptModule >>addInitialStmtsToAlgorithms<<
//
//   Real a[3];
// algorithm       -->  algorithm
//   a[1] := 1.0;         a[1] := $_start(a[1]);
//                        a[2] := $_start(a[2]);
//                        a[3] := $_start(a[3]);
//                        a[1] := 1.0;
// =============================================================================

public function addInitialStmtsToAlgorithms "
  section are executed in the order of appearance. Whenever an algorithm section is invoked, all variables appearing
  on the left hand side of the assignment operator := are initialized (at least conceptually):
    - A non-discrete variable is initialized with its start value (i.e. the value of the start-attribute).
    - A discrete variable v is initialized with pre(v)."
  input BackendDAE.BackendDAE inDAE;
  output BackendDAE.BackendDAE outDAE;
algorithm
  outDAE := BackendDAEUtil.mapEqSystem(inDAE, addInitialStmtsToAlgorithms1);
end addInitialStmtsToAlgorithms;

protected function addInitialStmtsToAlgorithms1 "Helper function to addInitialStmtsToAlgorithms."
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
  output BackendDAE.EqSystem osyst;
  output BackendDAE.Shared oshared;
algorithm
  (osyst, oshared) := match (syst, shared)
 local
  BackendDAE.Variables ordvars;
  BackendDAE.EquationArray ordeqns;
  BackendDAE.EqSystem eqs;
   case(eqs as BackendDAE.EQSYSTEM(orderedVars=ordvars, orderedEqs=ordeqns), _)
   equation
     (ordeqns, _) = BackendEquation.traverseBackendDAEEqnsWithUpdate(ordeqns, eaddInitialStmtsToAlgorithms1Helper, ordvars);
   then(eqs, shared);
   end match;
end addInitialStmtsToAlgorithms1;

protected function eaddInitialStmtsToAlgorithms1Helper "Helper function to addInitialStmtsToAlgorithms1."
  input BackendDAE.Equation inEq;
  input BackendDAE.Variables inVars;
  output BackendDAE.Equation outEq;
  output BackendDAE.Variables outVars;
algorithm
  (outEq,outVars) := match (inEq,inVars)
    local
      DAE.Algorithm alg;
      list<DAE.Statement> statements;
      BackendDAE.Equation eqn;
      BackendDAE.Variables vars;
      Integer size;
      list<DAE.Exp> outputs;
      DAE.ElementSource source;
      list<DAE.ComponentRef> crlst;
      DAE.Expand crExpand;
      BackendDAE.EquationAttributes attr;

    case (BackendDAE.ALGORITHM(size=size, alg=alg as DAE.ALGORITHM_STMTS(statements), source=source, expand=crExpand, attr=attr), vars)
      equation
        crlst = CheckModel.checkAndGetAlgorithmOutputs(alg, source, crExpand);
        outputs = List.map(crlst, Expression.crefExp);
        statements = expandAlgorithmStmts(statements, outputs, vars);
      then (BackendDAE.ALGORITHM(size, DAE.ALGORITHM_STMTS(statements), source, crExpand, attr), vars);

    else (inEq,inVars);
  end match;
end eaddInitialStmtsToAlgorithms1Helper;

protected function expandAlgorithmStmts "Helper function to eaddInitialStmtsToAlgorithms1Helper."
  input list<DAE.Statement> inAlg;
  input list<DAE.Exp> inOutputs;
  input BackendDAE.Variables inVars;
  output list<DAE.Statement> outAlg;
algorithm
  outAlg := match(inAlg, inOutputs, inVars)
    local
      DAE.Exp out, initExp;
      list<DAE.Exp> rest;
      DAE.ComponentRef cref;
      BackendDAE.Var var;
      DAE.Statement stmt;
      DAE.Type type_;
      list<DAE.Statement> statements;
      Boolean b;

    case(statements, {}, _)
    then statements;

    case(statements, out::rest, _) equation
      cref = Expression.expCref(out);
      type_ = Expression.typeof(out);
      type_ = Expression.arrayEltType(type_);
      (var::_, _) = BackendVariable.getVar(cref, inVars);
      b = BackendVariable.isVarDiscrete(var);
      initExp = Expression.makePureBuiltinCall(if b then "pre" else "$_start", {out}, type_);
      stmt = Algorithm.makeAssignment(DAE.CREF(cref, type_), DAE.PROP(type_, DAE.C_VAR()), initExp, DAE.PROP(type_, DAE.C_VAR()), DAE.dummyAttrVar, SCode.NON_INITIAL(), DAE.emptyElementSource);
    then expandAlgorithmStmts(stmt::statements, rest, inVars);
  end match;
end expandAlgorithmStmts;


// =============================================================================
// section for preOptModule >>encapsulateWhenConditions<<
//
// This module encapsulates each when-condition in a boolean-variable
// $whenConditionN and generates to each of these variables an equation
// $whenConditionN = conditionN
// =============================================================================

public function encapsulateWhenConditions "author: lochel"
  input BackendDAE.BackendDAE inDAE;
  output BackendDAE.BackendDAE outDAE;
protected
  BackendDAE.EqSystems systs;
  BackendDAE.Shared shared;
  BackendDAE.Variables knownVars;
  BackendDAE.Variables externalObjects;
  BackendDAE.Variables aliasVars;
  BackendDAE.EquationArray initialEqs;
  BackendDAE.EquationArray removedEqs;
  list<DAE.Constraint> constraints;
  list<DAE.ClassAttributes> classAttrs;
  FCore.Cache cache;
  FCore.Graph graph;
  DAE.FunctionTree functionTree;
  BackendDAE.EventInfo eventInfo;
  BackendDAE.ExternalObjectClasses extObjClasses;
  BackendDAE.BackendDAEType backendDAEType;
  BackendDAE.SymbolicJacobians symjacs;

  list<BackendDAE.TimeEvent> timeEvents;
  list<BackendDAE.WhenClause> whenClauseLst;
  list<BackendDAE.ZeroCrossing> zeroCrossingLst;
  list<BackendDAE.ZeroCrossing> sampleLst;
  list<BackendDAE.ZeroCrossing> relationsLst;
  Integer numberMathEvents;

  Integer index;
  HashTableExpToIndex.HashTable ht;   // is used to avoid redundant condition-variables
  list<BackendDAE.Var> vars;
  list<BackendDAE.Equation> eqns;
  BackendDAE.Variables vars_;
  BackendDAE.EquationArray eqns_;
  BackendDAE.ExtraInfo ei;
algorithm
  BackendDAE.DAE(systs, shared) := inDAE;
  BackendDAE.SHARED(knownVars=knownVars,
                    externalObjects=externalObjects,
                    aliasVars=aliasVars,
                    initialEqs=initialEqs,
                    removedEqs=removedEqs,
                    constraints=constraints,
                    classAttrs=classAttrs,
                    cache=cache,
                    graph=graph,
                    functionTree=functionTree,
                    eventInfo=eventInfo,
                    extObjClasses=extObjClasses,
                    backendDAEType=backendDAEType,
                    symjacs=symjacs,
                    info=ei) := shared;
  BackendDAE.EVENT_INFO(timeEvents=timeEvents,
                        whenClauseLst=whenClauseLst,
                        zeroCrossingLst=zeroCrossingLst,
                        sampleLst=sampleLst,
                        relationsLst=relationsLst,
                        numberMathEvents=numberMathEvents) := eventInfo;

  ht := HashTableExpToIndex.emptyHashTable();

  // equation system
  (systs, (index, ht)) := List.mapFold(systs, encapsulateWhenConditions1, (1, ht));

  // when clauses
  (whenClauseLst, vars, eqns, ht, index) := encapsulateWhenConditionsFromWhenClause(whenClauseLst, {}, {}, {}, ht, index);

  // removed equations
  ((removedEqs, vars, eqns, index, ht)) := BackendEquation.traverseBackendDAEEqns(removedEqs, encapsulateWhenConditions2, (BackendEquation.emptyEqns(), vars, eqns, index, ht));
  vars_ := BackendVariable.listVar(vars);
  eqns_ := BackendEquation.listEquation(eqns);
  systs := listAppend(systs, {BackendDAE.EQSYSTEM(vars_, eqns_, NONE(), NONE(), BackendDAE.NO_MATCHING(), {}, BackendDAE.UNKNOWN_PARTITION())});

  eventInfo := BackendDAE.EVENT_INFO(timeEvents,
                                     whenClauseLst,
                                     zeroCrossingLst,
                                     sampleLst,
                                     relationsLst,
                                     numberMathEvents);
  shared := BackendDAE.SHARED(knownVars,
                              externalObjects,
                              aliasVars,
                              initialEqs,
                              removedEqs,
                              constraints,
                              classAttrs,
                              cache,
                              graph,
                              functionTree,
                              eventInfo,
                              extObjClasses,
                              backendDAEType,
                              symjacs,
                              ei);
  outDAE := if intGt(index, 1) then BackendDAE.DAE(systs, shared) else inDAE;
  if Flags.isSet(Flags.DUMP_ENCAPSULATEWHENCONDITIONS) then
    BackendDump.dumpBackendDAE(outDAE, "DAE after PreOptModule >>encapsulateWhenConditions<<");
  end if;
end encapsulateWhenConditions;

protected function encapsulateWhenConditionsFromWhenClause "author: lochel"
  input list<BackendDAE.WhenClause> inWhenClause;
  input list<BackendDAE.WhenClause> inWhenClause_done;
  input list<BackendDAE.Var> inVars;
  input list<BackendDAE.Equation> inEqns;
  input HashTableExpToIndex.HashTable inHT;
  input Integer inIndex;
  output list<BackendDAE.WhenClause> outWhenClause;
  output list<BackendDAE.Var> outVars;
  output list<BackendDAE.Equation> outEqns;
  output HashTableExpToIndex.HashTable outHT;
  output Integer outIndex;
algorithm
  (outWhenClause, outVars, outEqns, outHT, outIndex) := match(inWhenClause, inWhenClause_done, inVars, inEqns, inHT, inIndex)
    local
      HashTableExpToIndex.HashTable ht;
      Integer index;
      DAE.Exp condition;
      list<BackendDAE.WhenOperator> reinitStmtLst;
      Option<Integer> elseClause;

      list<BackendDAE.Var> vars;
      list<BackendDAE.Equation> eqns;
      list<BackendDAE.WhenClause> rest, whenClause_done;

    case ({}, _, _, _, _, _) then (inWhenClause_done, inVars, inEqns, inHT, inIndex);

    case (BackendDAE.WHEN_CLAUSE(condition, reinitStmtLst, elseClause)::rest, _, _, _, ht, index) equation
      (condition, vars, eqns, index, ht) = encapsulateWhenConditionsForEquations1(condition, DAE.emptyElementSource, index, ht);
      vars = listAppend(vars, inVars);
      eqns = listAppend(eqns, inEqns);
      whenClause_done = listAppend({BackendDAE.WHEN_CLAUSE(condition, reinitStmtLst, elseClause)}, inWhenClause_done);

      (whenClause_done, vars, eqns, ht, index) = encapsulateWhenConditionsFromWhenClause(rest, whenClause_done, vars, eqns, ht, index);
    then (whenClause_done, vars, eqns, ht, index);
  end match;
end encapsulateWhenConditionsFromWhenClause;

protected function encapsulateWhenConditions1 "author: lochel
  This is a helper function for encapsulateWhenConditions."
  input BackendDAE.EqSystem inEqSystem;
  input tuple<Integer, HashTableExpToIndex.HashTable> inTpl;
  output BackendDAE.EqSystem outEqSystem;
  output tuple<Integer, HashTableExpToIndex.HashTable> outTpl;
protected
  BackendDAE.Variables orderedVars;
  BackendDAE.EquationArray orderedEqs;
  BackendDAE.StateSets stateSets;
  list<BackendDAE.Var> varLst;
  list<BackendDAE.Equation> eqnLst;
  Integer index;
  HashTableExpToIndex.HashTable ht;
  BackendDAE.BaseClockPartitionKind partitionKind;

algorithm
  BackendDAE.EQSYSTEM(orderedVars=orderedVars, orderedEqs=orderedEqs, stateSets=stateSets, partitionKind=partitionKind) := inEqSystem;
  (index, ht) := inTpl;

  ((orderedEqs, varLst, eqnLst, index, ht)) := BackendEquation.traverseBackendDAEEqns(orderedEqs, encapsulateWhenConditions2, (BackendEquation.emptyEqns(), {}, {}, index, ht));

  orderedVars := BackendVariable.addVars(varLst, orderedVars);
  orderedEqs := BackendEquation.addEquations(eqnLst, orderedEqs);

  outTpl := (index, ht);
  outEqSystem := BackendDAE.EQSYSTEM(orderedVars, orderedEqs, NONE(), NONE(), BackendDAE.NO_MATCHING(), stateSets, partitionKind);
end encapsulateWhenConditions1;

protected function encapsulateWhenConditions2 "author: lochel
  This is a helper function for encapsulateWhenConditions1."
  input BackendDAE.Equation inEq;
  input tuple<BackendDAE.EquationArray, list<BackendDAE.Var>, list<BackendDAE.Equation>, Integer, HashTableExpToIndex.HashTable> inTpl;
  output BackendDAE.Equation outEq;
  output tuple<BackendDAE.EquationArray, list<BackendDAE.Var>, list<BackendDAE.Equation>, Integer, HashTableExpToIndex.HashTable> outTpl;
algorithm
  (outEq,outTpl) := match (inEq,inTpl)
    local
      BackendDAE.Equation eqn, eqn2;
      list<BackendDAE.Var> vars, vars1;
      list<BackendDAE.Equation> eqns, eqns1;
      BackendDAE.WhenEquation whenEquation;
      DAE.ElementSource source;
      Integer index, size, sizePre;
      BackendDAE.EquationArray equationArray;
      DAE.Algorithm alg_;
      list<DAE.Statement> stmts, preStmts;
      HashTableExpToIndex.HashTable ht;
      DAE.Expand crefExpand;
      BackendDAE.EquationAttributes attr;

    // when equation
    case (BackendDAE.WHEN_EQUATION(size=size, whenEquation=whenEquation, source=source, attr=attr), (equationArray, vars, eqns, index, ht))
      equation
        (whenEquation, vars1, eqns1, index, ht) = encapsulateWhenConditionsForEquations(whenEquation, source, index, ht);
        vars = listAppend(vars, vars1);
        eqns = listAppend(eqns, eqns1);
        eqn = BackendDAE.WHEN_EQUATION(size, whenEquation, source, attr);
        equationArray = BackendEquation.addEquations({eqn}, equationArray);
      then (eqn, (equationArray, vars, eqns, index, ht));

    // removed algorithm
    case (BackendDAE.ALGORITHM(size=0, alg=alg_, source=source, expand=crefExpand, attr=attr), (equationArray, vars, eqns, index, ht))
      equation
        DAE.ALGORITHM_STMTS(statementLst=stmts) = alg_;
        size = -index;
        (stmts, preStmts, vars1, index) = encapsulateWhenConditionsForAlgorithms(stmts, vars, index);
        sizePre = listLength(preStmts);
        size = size+index-sizePre;

        alg_ = DAE.ALGORITHM_STMTS(stmts);
        eqn = BackendDAE.ALGORITHM(size, alg_, source, crefExpand, attr);
        equationArray = BackendEquation.addEquations({eqn}, equationArray);

        alg_ = DAE.ALGORITHM_STMTS(preStmts);
        eqn2 = BackendDAE.ALGORITHM(sizePre, alg_, source, crefExpand, attr);
        eqns = if intGt(sizePre, 0) then eqn2::eqns else eqns;
      then (eqn, (equationArray, vars1, eqns, index, ht));

    // algorithm
    case (BackendDAE.ALGORITHM(size=size, alg=alg_, source=source, expand=crefExpand, attr=attr), (equationArray, vars, eqns, index, ht))
      equation
      DAE.ALGORITHM_STMTS(statementLst=stmts) = alg_;
      size = size-index;
      (stmts, preStmts, vars1, index) = encapsulateWhenConditionsForAlgorithms(stmts, vars, index);
      size = size+index;

      stmts = listAppend(preStmts, stmts);

      alg_ = DAE.ALGORITHM_STMTS(stmts);
      eqn = BackendDAE.ALGORITHM(size, alg_, source, crefExpand, attr);
      equationArray = BackendEquation.addEquations({eqn}, equationArray);
      then (eqn, (equationArray, vars1, eqns, index, ht));

    case (eqn, (equationArray, vars, eqns, index, ht))
      equation
      equationArray = BackendEquation.addEquations({eqn}, equationArray);
      then (eqn, (equationArray, vars, eqns, index, ht));
  end match;
end encapsulateWhenConditions2;

protected function encapsulateWhenConditionsForEquations "author: lochel
  This is a helper function for encapsulateWhenConditions2."
  input BackendDAE.WhenEquation inWhenEquation;
  input DAE.ElementSource inSource;
  input Integer inIndex;
  input HashTableExpToIndex.HashTable inHT;
  output BackendDAE.WhenEquation outWhenEquation;
  output list<BackendDAE.Var> outVars;
  output list<BackendDAE.Equation> outEqns;
  output Integer outIndex;
  output HashTableExpToIndex.HashTable outHT;
algorithm
  (outWhenEquation, outVars, outEqns, outIndex, outHT) := matchcontinue(inWhenEquation, inSource, inIndex, inHT)
    local
      Integer index;
      BackendDAE.WhenEquation elsewhenPart, whenEquation;
      list<BackendDAE.Var> vars, vars1;
      list<BackendDAE.Equation> eqns, eqns1;

      DAE.Exp condition;
      DAE.ComponentRef left;
      DAE.Exp right;

      HashTableExpToIndex.HashTable ht;

    // when
    case (BackendDAE.WHEN_EQ(condition=condition, left=left, right=right, elsewhenPart=NONE()), _, index, ht) equation
      (condition, vars, eqns, index, ht) = encapsulateWhenConditionsForEquations1(condition, inSource, index, ht);
      whenEquation = BackendDAE.WHEN_EQ(condition, left, right, NONE());
    then (whenEquation, vars, eqns, index, ht);

    // when - elsewhen
    case (whenEquation as BackendDAE.WHEN_EQ(condition=condition, left=left, right=right, elsewhenPart=SOME(elsewhenPart)), _, index, ht) equation
      (elsewhenPart, vars1, eqns1, index, ht) = encapsulateWhenConditionsForEquations(elsewhenPart, inSource, index, ht);
      (condition, vars, eqns, index, ht) = encapsulateWhenConditionsForEquations1(condition, inSource, index, ht);
      whenEquation = BackendDAE.WHEN_EQ(condition, left, right, SOME(elsewhenPart));
      vars = listAppend(vars, vars1);
      eqns = listAppend(eqns, eqns1);
    then (whenEquation, vars, eqns, index, ht);

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"./Compiler/BackEnd/BackendDAEOptimize.mo: function encapsulateWhenConditionsForEquations failed"});
    then fail();
  end matchcontinue;
end encapsulateWhenConditionsForEquations;

protected function encapsulateWhenConditionsForEquations1 "author: lochel
  This is a helper function for encapsulateWhenConditionsForEquations."
  input DAE.Exp inCondition;
  input DAE.ElementSource inSource;
  input Integer inIndex;
  input HashTableExpToIndex.HashTable inHT;
  output DAE.Exp outCondition;
  output list<BackendDAE.Var> outVars;
  output list<BackendDAE.Equation> outEqns;
  output Integer outIndex;
  output HashTableExpToIndex.HashTable outHT;
algorithm
  (outCondition, outVars, outEqns, outIndex, outHT) := matchcontinue(inCondition, inSource, inIndex, inHT)
    local
      Integer index, localIndex;
      BackendDAE.Var var;
      BackendDAE.Equation eqn;
      list<BackendDAE.Var> vars;
      list<BackendDAE.Equation> eqns;
      String crStr;
      DAE.Exp crefPreExp;

      DAE.Exp condition;
      list<DAE.Exp> array;

      DAE.Type ty;
      Boolean scalar "scalar for codegen" ;

      HashTableExpToIndex.HashTable ht;

    // we do not replace initial()
    case (condition as DAE.CALL(path = Absyn.IDENT(name = "initial")), _, index, ht)
    then (condition, {}, {}, index, ht);

    // array-condition
    case (DAE.ARRAY(ty=ty, scalar=scalar, array=array), _, _, ht) equation
      (array, vars, eqns, index, ht) = encapsulateWhenConditionsForEquationsWithArrayConditions(array, inSource, inIndex, ht);
    then (DAE.ARRAY(ty, scalar, array), vars, eqns, index, ht);

    // simple condition [already in ht]
    case (condition, _, index, ht) equation
      localIndex = BaseHashTable.get(condition, ht);
      crStr = "$whenCondition" + intString(localIndex);
      condition = DAE.CREF(DAE.CREF_IDENT(crStr, DAE.T_BOOL_DEFAULT, {}), DAE.T_BOOL_DEFAULT);
    then (condition, {}, {}, index, ht);

    // simple condition [not yet in ht]
    case (condition, _, index, ht) equation
      ht = BaseHashTable.add((condition, index), ht);
      crStr = "$whenCondition" + intString(index);

      var = BackendDAE.VAR(DAE.CREF_IDENT(crStr, DAE.T_BOOL_DEFAULT, {}), BackendDAE.DISCRETE(), DAE.BIDIR(), DAE.NON_PARALLEL(), DAE.T_BOOL_DEFAULT, NONE(), NONE(), {}, inSource, NONE(), NONE(), DAE.NON_CONNECTOR());
      var = BackendVariable.setVarFixed(var, true);
      eqn = BackendDAE.EQUATION(DAE.CREF(DAE.CREF_IDENT(crStr, DAE.T_BOOL_DEFAULT, {}), DAE.T_BOOL_DEFAULT), condition, inSource, BackendDAE.EQ_ATTR_DEFAULT_DYNAMIC);

      condition = DAE.CREF(DAE.CREF_IDENT(crStr, DAE.T_BOOL_DEFAULT, {}), DAE.T_BOOL_DEFAULT);
    then (condition, {var}, {eqn}, index+1, ht);

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"./Compiler/BackEnd/BackendDAEOptimize.mo: function encapsulateWhenConditionsForEquations1 failed"});
    then fail();
  end matchcontinue;
end encapsulateWhenConditionsForEquations1;

protected function encapsulateWhenConditionsForEquationsWithArrayConditions "author: lochel
  This is a helper function for encapsulateWhenConditionsForEquations1."
  input list<DAE.Exp> inConditionList;
  input DAE.ElementSource inSource;
  input Integer inIndex;
  input HashTableExpToIndex.HashTable inHT;
  output list<DAE.Exp> outConditionList;
  output list<BackendDAE.Var> outVars;
  output list<BackendDAE.Equation> outEqns;
  output Integer outIndex;
  output HashTableExpToIndex.HashTable outHT;
algorithm
  (outConditionList, outVars, outEqns, outIndex, outHT) := matchcontinue(inConditionList, inSource, inIndex, inHT)
    local
      Integer index;
      list<BackendDAE.Var> vars1, vars2;
      list<BackendDAE.Equation> eqns1, eqns2;

      DAE.Exp condition;
      list<DAE.Exp> conditionList;

      HashTableExpToIndex.HashTable ht;

    case ({}, _, _, _) equation
    then ({}, {}, {}, inIndex, inHT);

    case (condition::conditionList, _, index, ht) equation
      (condition, vars1, eqns1, index, ht) = encapsulateWhenConditionsForEquations1(condition, inSource, index, ht);
      (conditionList, vars2, eqns2, index, ht) = encapsulateWhenConditionsForEquationsWithArrayConditions(conditionList, inSource, index, ht);
      vars1 = listAppend(vars1, vars2);
      eqns1 = listAppend(eqns1, eqns2);
    then (condition::conditionList, vars1, eqns1, index, ht);

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"./Compiler/BackEnd/BackendDAEOptimize.mo: function encapsulateWhenConditionsForEquationsWithArrayConditions failed"});
    then fail();
  end matchcontinue;
end encapsulateWhenConditionsForEquationsWithArrayConditions;

protected function encapsulateWhenConditionsForAlgorithms "author: lochel
  This is a helper function for encapsulateWhenConditions2."
  input list<DAE.Statement> inStmts;
  input list<BackendDAE.Var> inVars;
  input Integer inIndex;
  output list<DAE.Statement> outStmts;
  output list<DAE.Statement> outPreStmts; // these are additional statements that should be inserted directly before a STMT_WHEN
  output list<BackendDAE.Var> outVars;
  output Integer outIndex;
algorithm
  (outStmts, outPreStmts, outVars, outIndex) := matchcontinue(inStmts, inVars, inIndex)
    local
      DAE.Exp condition;
      DAE.Statement stmt, elseWhen;
      list<DAE.Statement> stmts, rest, stmts1, stmts_, preStmts, preStmts2, elseWhenList;
      Integer index;
      DAE.ElementSource source;
      list<BackendDAE.Var> vars;
      list<DAE.ComponentRef> conditions;
      Boolean initialCall;

    case ({}, _, _)
    then ({}, {}, inVars, inIndex);

    // when statement (without outputs)
    case ((DAE.STMT_WHEN(exp=condition, statementLst=stmts1, elseWhen=NONE(), source=source))::rest, _, _) equation
      (condition, vars, preStmts, index) = encapsulateWhenConditionsForAlgorithms1(condition, source, inIndex);
      (conditions, initialCall) = BackendDAEUtil.getConditionList(condition);
      vars = listAppend(vars, inVars);

      {} = CheckModel.algorithmStatementListOutputs({DAE.STMT_WHEN(condition, conditions, initialCall, stmts1, NONE(), source)}, DAE.EXPAND());

      (stmts, preStmts2, vars, index) = encapsulateWhenConditionsForAlgorithms(rest, vars, index);
      preStmts = listAppend(preStmts, preStmts2);
      stmts_ = listAppend({DAE.STMT_WHEN(condition, conditions, initialCall, stmts1, NONE(), source)}, stmts);
    then (stmts_, preStmts, vars, index);

    // when statement
    case ((DAE.STMT_WHEN(exp=condition, statementLst=stmts1, elseWhen=NONE(), source=source))::rest, _, _) equation
      (condition, vars, preStmts, index) = encapsulateWhenConditionsForAlgorithms1(condition, source, inIndex);
      (conditions, initialCall) = BackendDAEUtil.getConditionList(condition);
      vars = listAppend(vars, inVars);

      (stmts, stmts_, vars, index) = encapsulateWhenConditionsForAlgorithms(rest, vars, index);
      stmts_ = listAppend({DAE.STMT_WHEN(condition, conditions, initialCall, stmts1, NONE(), source)}, stmts_);
      stmts_ = listAppend(stmts_, stmts);
    then (stmts_, preStmts, vars, index);

    // when - elsewhen statement (without outputs)
    case ((DAE.STMT_WHEN(exp=condition, statementLst=stmts1, elseWhen=SOME(elseWhen), source=source))::rest, _, _) equation
      (condition, vars, preStmts, index) = encapsulateWhenConditionsForAlgorithms1(condition, source, inIndex);
      (conditions, initialCall) = BackendDAEUtil.getConditionList(condition);
      vars = listAppend(vars, inVars);

      (elseWhenList, _, vars, index) = encapsulateWhenConditionsForAlgorithms({elseWhen}, vars, index);
      elseWhen = List.last(elseWhenList);
      preStmts2 = List.stripLast(elseWhenList);
      preStmts = listAppend(preStmts, preStmts2);

      {} = CheckModel.algorithmStatementListOutputs({DAE.STMT_WHEN(condition, conditions, initialCall, stmts1, SOME(elseWhen), source)}, DAE.EXPAND());

      (stmts, preStmts2, vars, index) = encapsulateWhenConditionsForAlgorithms(rest, vars, index);
      preStmts = listAppend(preStmts, preStmts2);
      stmts_ = listAppend({DAE.STMT_WHEN(condition, conditions, initialCall, stmts1, SOME(elseWhen), source)}, stmts);
    then (stmts_, preStmts, vars, index);

    // when - elsewhen statement
    case ((DAE.STMT_WHEN(exp=condition, statementLst=stmts1, elseWhen=SOME(elseWhen), source=source))::rest, _, _) equation
      (condition, vars, preStmts, index) = encapsulateWhenConditionsForAlgorithms1(condition, source, inIndex);
      (conditions, initialCall) = BackendDAEUtil.getConditionList(condition);
      vars = listAppend(vars, inVars);

      ({elseWhen}, preStmts2, vars, index) = encapsulateWhenConditionsForAlgorithms({elseWhen}, vars, index);
      preStmts = listAppend(preStmts, preStmts2);

      (stmts, stmts_, vars, index) = encapsulateWhenConditionsForAlgorithms(rest, vars, index);
      stmts_ = listAppend({DAE.STMT_WHEN(condition, conditions, initialCall, stmts1, SOME(elseWhen), source)}, stmts_);
      stmts_ = listAppend(stmts_, stmts);
    then (stmts_, preStmts, vars, index);

    // no when statement
    case (stmt::rest, _, _) equation
      (stmts, preStmts, vars, index) = encapsulateWhenConditionsForAlgorithms(rest, inVars, inIndex);
      stmts = listAppend(preStmts, stmts);
    then (stmt::stmts, {}, vars, index);

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"./Compiler/BackEnd/BackendDAEOptimize.mo: function encapsulateWhenConditionsForAlgorithms failed"});
    then fail();
  end matchcontinue;
end encapsulateWhenConditionsForAlgorithms;

protected function encapsulateWhenConditionsForAlgorithms1 "author: lochel
  This is a helper function for encapsulateWhenConditionsForEquations."
  input DAE.Exp inCondition;
  input DAE.ElementSource inSource;
  input Integer inIndex;
  output DAE.Exp outCondition;
  output list<BackendDAE.Var> outVars;
  output list<DAE.Statement> outStmts;
  output Integer outIndex;
algorithm
  (outCondition, outVars, outStmts, outIndex) := matchcontinue(inCondition, inSource, inIndex)
    local
      Integer index;
      BackendDAE.Var var;
      DAE.Statement stmt;
      list<BackendDAE.Var> vars;
      list<DAE.Statement> stmts;
      String crStr;
      DAE.Exp crefPreExp;

      DAE.Exp condition;
      list<DAE.Exp> array;

      DAE.Type ty;
      Boolean scalar "scalar for codegen" ;

    // we do not replace initial()
    case (condition as DAE.CALL(path = Absyn.IDENT(name = "initial")), _, index)
    then (condition, {}, {}, index);

    // array-condition
    case (DAE.ARRAY(array={condition}), _, index) equation
      crStr = "$whenCondition" + intString(index);

      var = BackendDAE.VAR(DAE.CREF_IDENT(crStr, DAE.T_BOOL_DEFAULT, {}), BackendDAE.DISCRETE(), DAE.BIDIR(), DAE.NON_PARALLEL(), DAE.T_BOOL_DEFAULT, NONE(), NONE(), {}, inSource, NONE(), NONE(), DAE.NON_CONNECTOR());
      var = BackendVariable.setVarFixed(var, true);
      stmt = DAE.STMT_ASSIGN(DAE.T_BOOL_DEFAULT, DAE.CREF(DAE.CREF_IDENT(crStr, DAE.T_BOOL_DEFAULT, {}), DAE.T_BOOL_DEFAULT), condition, inSource);

      condition = DAE.CREF(DAE.CREF_IDENT(crStr, DAE.T_BOOL_DEFAULT, {}), DAE.T_BOOL_DEFAULT);
    then (condition, {var}, {stmt}, index+1);

    // array-condition
    case (DAE.ARRAY(ty=ty, scalar=scalar, array=array), _, _) equation
      (array, vars, stmts, index) = encapsulateWhenConditionsForAlgorithmsWithArrayConditions(array, inSource, inIndex);
    then (DAE.ARRAY(ty, scalar, array), vars, stmts, index);

    // simple condition
    case (condition, _, index) equation
      crStr = "$whenCondition" + intString(index);

      var = BackendDAE.VAR(DAE.CREF_IDENT(crStr, DAE.T_BOOL_DEFAULT, {}), BackendDAE.DISCRETE(), DAE.BIDIR(), DAE.NON_PARALLEL(), DAE.T_BOOL_DEFAULT, NONE(), NONE(), {}, inSource, NONE(), NONE(), DAE.NON_CONNECTOR());
      var = BackendVariable.setVarFixed(var, true);
      stmt = DAE.STMT_ASSIGN(DAE.T_BOOL_DEFAULT, DAE.CREF(DAE.CREF_IDENT(crStr, DAE.T_BOOL_DEFAULT, {}), DAE.T_BOOL_DEFAULT), condition, inSource);

      condition = DAE.CREF(DAE.CREF_IDENT(crStr, DAE.T_BOOL_DEFAULT, {}), DAE.T_BOOL_DEFAULT);
    then (condition, {var}, {stmt}, index+1);

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"./Compiler/BackEnd/BackendDAEOptimize.mo: function encapsulateWhenConditionsForAlgorithms1 failed"});
    then fail();
  end matchcontinue;
end encapsulateWhenConditionsForAlgorithms1;

protected function encapsulateWhenConditionsForAlgorithmsWithArrayConditions "author: lochel
  This is a helper function for encapsulateWhenConditionsForAlgorithms1."
  input list<DAE.Exp> inConditionList;
  input DAE.ElementSource inSource;
  input Integer inIndex;
  output list<DAE.Exp> outConditionList;
  output list<BackendDAE.Var> outVars;
  output list<DAE.Statement> outStmts;
  output Integer outIndex;
algorithm
  (outConditionList, outVars, outStmts, outIndex) := matchcontinue(inConditionList, inSource, inIndex)
    local
      Integer index;
      list<BackendDAE.Var> vars1, vars2;
      list<DAE.Statement> stmt1, stmt2;

      DAE.Exp condition;
      list<DAE.Exp> conditionList;

    case ({}, _, _) equation
    then ({}, {}, {}, inIndex);

    case (condition::conditionList, _, index) equation
      (condition, vars1, stmt1, index) = encapsulateWhenConditionsForAlgorithms1(condition, inSource, index);
      (conditionList, vars2, stmt2, index) = encapsulateWhenConditionsForAlgorithmsWithArrayConditions(conditionList, inSource, index);
      vars1 = listAppend(vars1, vars2);
      stmt1 = listAppend(stmt1, stmt2);
    then (condition::conditionList, vars1, stmt1, index);

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"./Compiler/BackEnd/BackendDAEOptimize.mo: function encapsulateWhenConditionsForAlgorithmsWithArrayConditions failed"});
    then fail();
  end matchcontinue;
end encapsulateWhenConditionsForAlgorithmsWithArrayConditions;

// =============================================================================
// section for expandDerOperator
//
// =============================================================================

public function expandDerOperator "
  Expands der(expr) using Derive.differentiteExpTime.
  This can not be done in Static, since we need all time-
  dependent variables, which is only available in BackendDAE."
  input BackendDAE.BackendDAE inDAE;
  output BackendDAE.BackendDAE outDAE;
algorithm
  outDAE := BackendDAEUtil.mapEqSystem(inDAE, expandDerOperatorWork);
end expandDerOperator;

protected function expandDerOperatorWork "
  expands der(expr) using Derive.differentiteExpTime.
  This can not be done in Static, since we need all time-
  dependent variables, which is only available in BackendDAE."
  input BackendDAE.EqSystem syst;
  input BackendDAE.Shared shared;
  output BackendDAE.EqSystem osyst;
  output BackendDAE.Shared oshared;
algorithm
  (osyst, oshared) := match (syst, shared)
    local
      Option<BackendDAE.IncidenceMatrix> m, mT;
      BackendDAE.Variables vars, knvars, exobj, vars1, vars2, av;
      BackendDAE.EquationArray eqns, remeqns, inieqns, eqns1, inieqns1;
      list<DAE.Constraint> constrs;
      list<DAE.ClassAttributes> clsAttrs;
      BackendDAE.EventInfo einfo;
      BackendDAE.ExternalObjectClasses eoc;
      BackendDAE.BackendDAEType btp;
      BackendDAE.Matching matching;
      DAE.FunctionTree funcs;
      BackendDAE.SymbolicJacobians symjacs;
      FCore.Cache cache;
      FCore.Graph graph;
      BackendDAE.StateSets stateSets;
      BackendDAE.ExtraInfo ei;
      BackendDAE.BaseClockPartitionKind partitionKind;

    case (BackendDAE.EQSYSTEM(vars, eqns, m, mT, matching, stateSets, partitionKind), BackendDAE.SHARED(knvars, exobj, av, inieqns, remeqns, constrs, clsAttrs, cache, graph, funcs, einfo, eoc, btp, symjacs,ei))
      equation
        (eqns1, (vars1, _)) = BackendEquation.traverseBackendDAEEqnsWithUpdate(eqns, traverserexpandDerEquation, (vars, shared));
        (inieqns1, (vars2, _)) = BackendEquation.traverseBackendDAEEqnsWithUpdate(inieqns, traverserexpandDerEquation, (vars1, shared));
      then
        (BackendDAE.EQSYSTEM(vars2, eqns1, m, mT, matching, stateSets, partitionKind), BackendDAE.SHARED(knvars, exobj, av, inieqns1, remeqns, constrs, clsAttrs, cache, graph, funcs, einfo, eoc, btp, symjacs,ei));
  end match;
end expandDerOperatorWork;

protected function traverserexpandDerEquation "
  Help function to e.g. traverserexpandDerEquation"
  input BackendDAE.Equation inEq;
  input tuple<BackendDAE.Variables, BackendDAE.Shared> tpl;
  output BackendDAE.Equation outEq;
  output tuple<BackendDAE.Variables, BackendDAE.Shared> outTpl;
protected
   BackendDAE.Equation e, e1;
   tuple<BackendDAE.Variables, DAE.FunctionTree> ext_arg, ext_art1;
   BackendDAE.Variables vars;
   DAE.FunctionTree funcs;
   Boolean b;
   list<DAE.SymbolicOperation> ops;
   BackendDAE.Shared shared;
algorithm
  e := inEq;
  (vars, shared) := tpl;
  (e1, (vars, shared, ops)) := BackendEquation.traverseBackendDAEExpsEqn(e, traverserexpandDerExp, (vars, shared, {}));
  e1 := List.foldr(ops, BackendEquation.addOperation, e1);
  outEq := e1;
  outTpl := (vars, shared);
end traverserexpandDerEquation;

protected function traverserexpandDerExp "
  Help function to e.g. traverserexpandDerExp"
  input DAE.Exp inExp;
  input tuple<BackendDAE.Variables, BackendDAE.Shared, list<DAE.SymbolicOperation>> tpl;
  output DAE.Exp outExp;
  output tuple<BackendDAE.Variables, BackendDAE.Shared, list<DAE.SymbolicOperation>> outTpl;
protected
  DAE.Exp e, e1;
  tuple<BackendDAE.Variables, BackendDAE.Shared, Boolean> ext_arg;
  BackendDAE.Variables vars;
  list<DAE.SymbolicOperation> ops;
  DAE.FunctionTree funcs;
  Boolean b;
  BackendDAE.Shared shared;
algorithm
  e := inExp;
  (vars, shared, ops) := tpl;
  ext_arg := (vars, shared, false);
  (e1, ext_arg) := Expression.traverseExp(e, expandDerExp, ext_arg);
  (vars, shared, b) := ext_arg;
  ops := List.consOnTrue(b, DAE.OP_DIFFERENTIATE(DAE.crefTime, e, e1), ops);
  outExp := e1;
  outTpl := (vars, shared, ops);
end traverserexpandDerExp;

protected function expandDerExp "
  Help function to e.g. expandDerOperatorEqn"
  input DAE.Exp inExp;
  input tuple<BackendDAE.Variables, BackendDAE.Shared, Boolean> itpl;
  output DAE.Exp e;
  output tuple<BackendDAE.Variables, BackendDAE.Shared, Boolean> tpl;
algorithm
  (e,tpl) := matchcontinue (inExp,itpl)
    local
      BackendDAE.Variables vars;
      DAE.Exp e1, e2;
      DAE.ComponentRef cr;
      String str;
      BackendDAE.Shared shared;
      list<BackendDAE.Var> varlst;
      BackendDAE.Var v;
      Boolean b;
      DAE.FunctionTree funcs;
    case (DAE.CALL(path=Absyn.IDENT(name = "der"), expLst={DAE.CALL(path=Absyn.IDENT(name = "der"), expLst={DAE.CREF(componentRef=cr)})}), (_, _, _))
      equation
        str = ComponentReference.crefStr(cr);
        str = stringAppendList({"The model includes derivatives of order > 1 for: ", str, ". That is not supported. Real d", str, " = der(", str, ") *might* result in a solvable model"});
        Error.addMessage(Error.INTERNAL_ERROR, {str});
      then fail();
    // case for arrays
    case (e1 as DAE.CALL(path=Absyn.IDENT(name = "der"), expLst={DAE.CREF(ty = DAE.T_ARRAY())}), (vars, shared as BackendDAE.SHARED(), b))
      equation
        (e2, true) = Expression.extendArrExp(e1, false);
        (e,tpl) = Expression.traverseExp(e2, expandDerExp, (vars, shared, b));
      then (e,tpl);
    // case for records
    case (e1 as DAE.CALL(path=Absyn.IDENT(name = "der"), expLst={DAE.CREF(ty = DAE.T_COMPLEX(complexClassType=ClassInf.RECORD(_)))}), (vars, shared as BackendDAE.SHARED(), b))
      equation
        (e2, true) = Expression.extendArrExp(e1, false);
        (e,tpl) = Expression.traverseExp(e2, expandDerExp, (vars, shared, b));
      then (e,tpl);
    case (e1 as DAE.CALL(path=Absyn.IDENT(name = "der"), expLst={DAE.CREF(componentRef=cr)}), (vars, shared, _))
      equation
        ({v}, _) = BackendVariable.getVar(cr, vars);
        (vars, e1) = updateStatesVar(vars, v, e1);
      then (e1, (vars, shared, true));
    case (e1 as DAE.CALL(path=Absyn.IDENT(name = "der"), expLst={DAE.CREF(componentRef=cr)}), (vars, shared, _))
      equation
        (varlst, _) = BackendVariable.getVar(cr, vars);
        vars = updateStatesVars(vars, varlst, false);
      then (e1, (vars, shared, true));
    case (DAE.CALL(path=Absyn.IDENT(name = "der"), expLst={e1}), (vars, shared, _))
      equation
        (e2, shared) = Differentiate.differentiateExpTime(e1, vars, shared);
        (e2, _) = ExpressionSimplify.simplify(e2);
        (_, vars) = Expression.traverseExp(e2, derCrefsExp, vars);
      then (e2, (vars, shared, true));
    else (inExp,itpl);
  end matchcontinue;
end expandDerExp;

protected function derCrefsExp "helper for statesExp"
  input DAE.Exp inExp;
  input BackendDAE.Variables inVars;
  output DAE.Exp outExp;
  output BackendDAE.Variables outVars;
algorithm
  (outExp,outVars) := matchcontinue (inExp,inVars)
  local
    DAE.ComponentRef cr;
    BackendDAE.Variables vars;
    list<BackendDAE.Var> varlst;
    BackendDAE.Var v;
    DAE.Exp e;
    case (e as DAE.CALL(path = Absyn.IDENT(name = "der"), expLst = {DAE.CREF(componentRef = cr)}), vars)
    equation
      ({v}, _) = BackendVariable.getVar(cr, vars);
      (vars, e) = updateStatesVar(vars, v, e);
      then (e, vars);
    case (e as DAE.CALL(path = Absyn.IDENT(name = "der"), expLst = {DAE.CREF(componentRef = cr)}), vars)
    equation
      (varlst, _) = BackendVariable.getVar(cr, vars);
      vars = updateStatesVars(vars, varlst, false);
      then (e, vars);
    else (inExp,inVars);
end matchcontinue;
end derCrefsExp;

protected function updateStatesVar "
  Help function to expandDerExp"
  input BackendDAE.Variables inVars;
  input BackendDAE.Var var;
  input DAE.Exp iExp;
  output BackendDAE.Variables outVars;
  output DAE.Exp oExp;
algorithm
  (outVars, oExp) := matchcontinue(inVars, var, iExp)
    local
      BackendDAE.Variables vars;
      BackendDAE.Var var1;
    case(_, _, _)
      equation
        true = BackendVariable.isVarDiscrete(var) "do not change discrete vars to states, because they have no derivative" ;
      then (inVars, DAE.RCONST(0.0));
    case(_, _, _)
      equation
        false = BackendVariable.isVarDiscrete(var) "do not change discrete vars to states, because they have no derivative" ;
        false = BackendVariable.isStateVar(var);
        var1 = BackendVariable.setVarKind(var, BackendDAE.STATE(1,NONE()));
        vars = BackendVariable.addVar(var1, inVars);
      then (vars, iExp);
    case(_, _, _)
      equation
        /* Might be part of a different equation-system...
        str = "BackendDAECreate.updateStatesVars failed for: " + ComponentReference.printComponentRefStr(cr);
        Error.addMessage(Error.INTERNAL_ERROR, {str});
        */
      then (inVars, iExp);
  end matchcontinue;
end updateStatesVar;

protected function updateStatesVars "
  Help function to expandDerExp"
  input BackendDAE.Variables inVars;
  input list<BackendDAE.Var> inNewStates;
  input Boolean noStateFound;
  output BackendDAE.Variables outVars;
algorithm
  outVars := matchcontinue(inVars, inNewStates, noStateFound)
    local
      BackendDAE.Var var;
      list<BackendDAE.Var> newStates;
      BackendDAE.Variables vars;
      //DAE.ComponentRef cr;
      //String str;

    case(_, {}, true) then inVars;
    case(_, var::newStates, _)
      equation
        false = BackendVariable.isVarDiscrete(var) "do not change discrete vars to states, because they have no derivative" ;
        false = BackendVariable.isStateVar(var);
        var = BackendVariable.setVarKind(var, BackendDAE.STATE(1,NONE()));
        vars = BackendVariable.addVar(var, inVars);
        vars = updateStatesVars(vars, newStates, true);
      then vars;
    case(_, _::newStates, _)
      equation
        /* Might be part of a different equation-system...
        str = "BackendDAECreate.updateStatesVars failed for: " + ComponentReference.printComponentRefStr(cr);
        Error.addMessage(Error.INTERNAL_ERROR, {str});
        */
        vars = updateStatesVars(inVars, newStates, noStateFound);
      then vars;
  end matchcontinue;
end updateStatesVars;

// =============================================================================
// replace expression with rewritten expression
//
// =============================================================================

public function applyRewriteRulesBackend
"@author: adrpo"
  input BackendDAE.BackendDAE inDAE;
  output BackendDAE.BackendDAE outDAE;
algorithm
  (outDAE, _) := BackendDAEUtil.mapEqSystemAndFold(inDAE, applyRewriteRulesBackend0, false);
  outDAE := applyRewriteRulesBackendShared(outDAE);
end applyRewriteRulesBackend;

protected function applyRewriteRulesBackend0
"@author: adrpo"
  input BackendDAE.EqSystem isyst;
  input tuple<BackendDAE.Shared, Boolean> sharedChanged;
  output BackendDAE.EqSystem osyst;
  output tuple<BackendDAE.Shared, Boolean> osharedChanged;
algorithm
  (osyst, osharedChanged) := matchcontinue (isyst, sharedChanged)
    local
      BackendDAE.Variables orderedVars;
      BackendDAE.EquationArray orderedEqs;
      Option<BackendDAE.IncidenceMatrix> m;
      Option<BackendDAE.IncidenceMatrixT> mT;
      BackendDAE.Matching matching;
      BackendDAE.Shared shared;
      BackendDAE.StateSets stateSets;
      FCore.Cache cache;
      FCore.Graph graph;
      BackendDAE.BaseClockPartitionKind partitionKind;

    case (BackendDAE.EQSYSTEM(orderedVars, orderedEqs, m, mT, matching, stateSets, partitionKind), (shared, _))
      equation
        _ = BackendDAEUtil.traverseBackendDAEExpsVarsWithUpdate(orderedVars, traverserapplyRewriteRulesBackend, false);
        _ = BackendDAEUtil.traverseBackendDAEExpsEqnsWithUpdate(orderedEqs, traverserapplyRewriteRulesBackend, false);
    then
      (BackendDAE.EQSYSTEM(orderedVars, orderedEqs, m, mT, matching, stateSets, partitionKind), (shared, true));

    else (isyst, sharedChanged);
  end matchcontinue;
end applyRewriteRulesBackend0;

protected function traverserapplyRewriteRulesBackend
"@author: adrpo"
  input DAE.Exp inExp;
  input Boolean inB;
  output DAE.Exp outExp;
  output Boolean outB;
algorithm
  (outExp,outB) := Expression.traverseExp(inExp,traverserExpapplyRewriteRulesBackend,inB);
end traverserapplyRewriteRulesBackend;

protected function traverserExpapplyRewriteRulesBackend
"@author: adrpo"
  input DAE.Exp inExp;
  input Boolean inB;
  output DAE.Exp outExp;
  output Boolean outB;
algorithm
  (outExp,outB) := matchcontinue(inExp,inB)
    local
      DAE.Exp e;
      FCore.Cache cache;
      FCore.Graph graph;

    // apply rewrite rule
    case (e, _) equation
      (e, true) = RewriteRules.rewriteBackEnd(e);
    then (e, true);

    else (inExp,inB);
  end matchcontinue;
end traverserExpapplyRewriteRulesBackend;

protected function applyRewriteRulesBackendShared
"@author: adrpo"
  input BackendDAE.BackendDAE inDAE;
  output BackendDAE.BackendDAE outDAE;
protected
  BackendDAE.Variables knvars, exobj, aliasVars;
  BackendDAE.EquationArray remeqns, inieqns;
  list<DAE.Constraint> constrs;
  list<DAE.ClassAttributes> clsAttrs;
  FCore.Cache cache;
  FCore.Graph graph;
  DAE.FunctionTree funcTree;
  BackendDAE.ExternalObjectClasses eoc;
  BackendDAE.SymbolicJacobians symjacs;
  BackendDAE.EventInfo eventInfo;
  BackendDAE.BackendDAEType btp;
  BackendDAE.EqSystems systs;
  BackendDAE.ExtraInfo ei;
algorithm
  BackendDAE.DAE(systs, BackendDAE.SHARED(knvars, exobj, aliasVars, inieqns, remeqns, constrs, clsAttrs, cache, graph, funcTree, eventInfo, eoc, btp, symjacs, ei)) := inDAE;
  _ := BackendDAEUtil.traverseBackendDAEExpsVarsWithUpdate(knvars,traverserapplyRewriteRulesBackend, false);
  _ := BackendDAEUtil.traverseBackendDAEExpsEqnsWithUpdate(inieqns,traverserapplyRewriteRulesBackend, false);
  _ := BackendDAEUtil.traverseBackendDAEExpsEqnsWithUpdate(remeqns,traverserapplyRewriteRulesBackend, false);
  // not sure if we should apply the rules on the event info!
  // (ei,_) = traverseEventInfoExps(eventInfo,traverserapplyRewriteRulesBackend, false);
  outDAE := BackendDAE.DAE(systs, BackendDAE.SHARED(knvars, exobj, aliasVars, inieqns, remeqns, constrs, clsAttrs, cache, graph, funcTree, eventInfo, eoc, btp, symjacs, ei));
end applyRewriteRulesBackendShared;

// =============================================================================
// generates a list with all iteration variables
//
// =============================================================================

public function listAllIterationVariables "author: lochel"
  input BackendDAE.BackendDAE inBackendDAE;
protected
  list<BackendDAE.EqSystem> eqs;
  BackendDAE.BackendDAEType backendDAEType;
  list<String> warnings;
algorithm
  BackendDAE.DAE(eqs=eqs, shared=BackendDAE.SHARED(backendDAEType=backendDAEType)) := inBackendDAE;
  warnings := listAllIterationVariables0(eqs);

  Error.addCompilerNotification("List of all iteration variables (DAE kind: " + BackendDump.printBackendDAEType2String(backendDAEType) + ")\n" + stringDelimitList(warnings, "\n"));
end listAllIterationVariables;

protected function listAllIterationVariables0 "author: lochel"
  input list<BackendDAE.EqSystem> inEqs;
  output list<String> outWarnings;
algorithm
  outWarnings := match(inEqs)
    local
      BackendDAE.EqSystem eq;
      list<BackendDAE.EqSystem> eqs;
      list<String> warning;
      list<String> warningList;

    case ({})
    then {};

    case (eq::eqs) equation
      warning = listAllIterationVariables1(eq);
      warningList = listAllIterationVariables0(eqs);
    then listAppend(warning, warningList);
  end match;
end listAllIterationVariables0;

protected function listAllIterationVariables1 "author: lochel"
  input BackendDAE.EqSystem inEqSystem;
  output list<String> outWarning;
protected
  BackendDAE.Variables vars;
  BackendDAE.StrongComponents comps;
algorithm
  BackendDAE.EQSYSTEM(orderedVars=vars,
                      matching=BackendDAE.MATCHING(comps=comps)) := inEqSystem;
  outWarning := listAllIterationVariables2(comps, vars);
end listAllIterationVariables1;

protected function listAllIterationVariables2 "author: lochel"
  input BackendDAE.StrongComponents inComps;
  input BackendDAE.Variables inVars;
  output list<String> outWarning;
algorithm
  outWarning := matchcontinue(inComps, inVars)
    local
      BackendDAE.StrongComponents rest;
      list<BackendDAE.Var> varlst;
      list<Integer> vlst;
      Boolean linear;
      String str;
      String warning;
      list<String> warningList;

    case ({}, _)
    then {};

    case (BackendDAE.EQUATIONSYSTEM(vars=vlst, jacType=BackendDAE.JAC_NONLINEAR())::rest, _) equation
      varlst = List.map1r(vlst, BackendVariable.getVarAt, inVars);
      false = List.isEmpty(varlst);

      warning = "Iteration variables of nonlinear equation system:\n" + warnAboutVars(varlst);
      warningList = listAllIterationVariables2(rest, inVars);
    then warning::warningList;

     case (BackendDAE.EQUATIONSYSTEM(vars=vlst, jacType=BackendDAE.JAC_GENERIC())::rest, _) equation
      varlst = List.map1r(vlst, BackendVariable.getVarAt, inVars);
      false = List.isEmpty(varlst);

      warning = "Iteration variables of equation system w/o analytic Jacobian:\n" + warnAboutVars(varlst);
      warningList = listAllIterationVariables2(rest, inVars);
    then warning::warningList;

    case (BackendDAE.EQUATIONSYSTEM(vars=vlst, jacType=BackendDAE.JAC_NO_ANALYTIC())::rest, _) equation
      varlst = List.map1r(vlst, BackendVariable.getVarAt, inVars);
      false = List.isEmpty(varlst);

      warning = "Iteration variables of equation system w/o analytic Jacobian:\n" + warnAboutVars(varlst);
      warningList = listAllIterationVariables2(rest, inVars);
    then warning::warningList;

    case (BackendDAE.TORNSYSTEM(tearingvars=vlst, linear=linear)::rest, _) equation
      varlst = List.map1r(vlst, BackendVariable.getVarAt, inVars);
      false = List.isEmpty(varlst);

      str = if linear then "linear" else "nonlinear";
      warning = "Iteration variables of torn " + str + " equation system:\n" + warnAboutVars(varlst);
      warningList = listAllIterationVariables2(rest, inVars);
    then warning::warningList;

    case (_::rest, _) equation
      warningList = listAllIterationVariables2(rest, inVars);
    then warningList;
  end matchcontinue;
end listAllIterationVariables2;

protected function warnAboutVars "author: lochel"
  input list<BackendDAE.Var> inVars;
  output String outString;
algorithm
  outString := match(inVars)
    local
      BackendDAE.Var v;
      list<BackendDAE.Var> vars;
      String crStr;
      String str;

    case ({})
    then "";

    case (v::{}) equation
      crStr = "  " + BackendDump.varString(v);
    then crStr;

    case (v::vars) equation
      crStr = BackendDump.varString(v);
      str = "  " + crStr + "\n" + warnAboutVars(vars);
    then str;
  end match;
end warnAboutVars;

annotation(__OpenModelica_Interface="backend");
end BackendDAEOptimize;
