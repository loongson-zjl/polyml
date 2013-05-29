(*
    Copyright (c) 2012,13 David C.J. Matthews

    This library is free software; you can redistribute it and/or
    modify it under the terms of the GNU Lesser General Public
    License as published by the Free Software Foundation; either
    version 2.1 of the License, or (at your option) any later version.
    
    This library is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
    Lesser General Public License for more details.
    
    You should have received a copy of the GNU Lesser General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
*)

functor CODETREE_OPTIMISER(
    structure BASECODETREE: BaseCodeTreeSig

    structure CODETREE_FUNCTIONS: CodetreeFunctionsSig

    structure REMOVE_REDUNDANT:
    sig
        type codetree
        type loadForm
        type codeUse
        val cleanProc : (codetree * codeUse list * (int -> loadForm) * int) -> codetree
        structure Sharing: sig type codetree = codetree and loadForm = loadForm and codeUse = codeUse end
    end

    structure SIMPLIFIER:
    sig
        type codetree and codeBinding and envSpecial

        val simplifier:
            codetree * int -> (codetree * codeBinding list * envSpecial) * int * bool
        val specialToGeneral:
            codetree * codeBinding list * envSpecial -> codetree

        structure Sharing:
        sig
            type codetree = codetree
            and codeBinding = codeBinding
            and envSpecial = envSpecial
        end
    end

    structure DEBUG :
    sig
        val codetreeTag:            bool Universal.tag (* If true then print the original code. *)
        val maxInlineSizeTag:       int  Universal.tag
        val getParameter : 'a Universal.tag -> Universal.universal list -> 'a
    end

    structure PRETTY : PRETTYSIG

    structure BACKEND:
    sig
        type codetree
        type machineWord = Address.machineWord
        val codeGenerate:
            codetree * int * Universal.universal list -> (unit -> machineWord) * Universal.universal list
        structure Sharing : sig type codetree = codetree end
    end

    sharing 
        BASECODETREE.Sharing 
    =   CODETREE_FUNCTIONS.Sharing
    =   REMOVE_REDUNDANT.Sharing
    =   SIMPLIFIER.Sharing
    =   PRETTY.Sharing
    =   BACKEND.Sharing

) :
    sig
        type codetree and envSpecial and codeBinding
        val codetreeOptimiser: codetree  * Universal.universal list * int ->
            { numLocals: int, general: codetree, bindings: codeBinding list, special: envSpecial }
        structure Sharing: sig type codetree = codetree and envSpecial = envSpecial and codeBinding = codeBinding end
    end
=
struct
    open BASECODETREE
    open Address
    open CODETREE_FUNCTIONS
    open StretchArray
    
    infix 9 sub
    
    exception InternalError = Misc.InternalError

 
    datatype inlineTest =
        TooBig
    |   NonRecursive
    |   TailRecursive of bool vector
    |   NonTailRecursive of bool vector

    fun evaluateInlining(function, numArgs, maxInlineSize) =
    let
        (* This checks for the possibility of inlining a function.  It sees if it is
           small enough according to some rough estimate of the cost and it also looks
           for recursive uses of the function.
           Typically if the function is small enough to inline there will be only
           one recursive use but we consider the possibility of more than one.  If
           the only uses are tail recursive we can replace the recursive calls by
           a Loop with a BeginLoop outside it.  If there are non-tail recursive
           calls we may be able to lift out arguments that are unchanged.  For
           example for fun map f [] = [] | map f (a::b) = f a :: map f b 
           it may be worth lifting out f and generating specific mapping
           functions for each application. *)
        val hasRecursiveCall = ref false (* Set to true if rec call *)
        val allTail = ref true (* Set to false if non recursive *)
        (* An element of this is set to false if the actual value if anything
           other than the original argument.  At the end we are then
           left with the arguments that are unchanged. *)
        val argMod = Array.array(numArgs, true)

        infix 6 --
        (* Subtract y from x but return 0 rather than a negative number. *)
        fun x -- y = if x >= y then x-y else 0

        (* Check for the code size and also recursive references.  N,B. We assume in hasLoop
           that tail recursion applies only with Cond, Newenv and Handler. *)
        fun checkUse _ (_, 0, _) = 0 (* The function is too big to inline. *)
 
        |   checkUse isMain (Newenv(decs, exp), cl, isTail) =
            let
                fun checkBind (Declar{value, ...}, cl) = checkUse isMain(value, cl, false)
                |   checkBind (RecDecs decs, cl) = List.foldl(fn ({lambda, ...}, n) => checkUse isMain (Lambda lambda, n, false)) cl decs
                |   checkBind (NullBinding c, cl) = checkUse isMain (c, cl, false)
                |   checkBind (Container{setter, ...}, cl) = checkUse isMain(setter, cl -- 1, false)
            in
                checkUse isMain (exp, List.foldl checkBind cl decs, isTail)
            end

        |   checkUse _      (Constnt(w, _), cl, _) = if isShort w then cl else cl -- 1

            (* A recursive reference in any context other than a call prevents any inlining. *)
        |   checkUse true   (Extract LoadRecursive, _, _) = 0
        |   checkUse _      (Extract _, cl, _) = cl -- 1

        |   checkUse isMain (Indirect{base, ...}, cl, _) = checkUse isMain (base, cl -- 1, false)

        |   checkUse _      (Lambda {body, argTypes, closure, ...}, cl, _) =
                (* For the moment, any recursive use in an inner function prevents inlining. *)
                if List.exists (fn LoadRecursive => true | _ => false) closure
                then 0
                else checkUse false (body, cl -- (List.length argTypes + List.length closure), false)

        |   checkUse true (Eval{function = Extract LoadRecursive, argList, ...}, cl, isTail) =
            let
                (* If the actual argument is anything but the original argument
                   then the corresponding entry in the array is set to false. *)
                fun testArg((exp, _), n) =
                (
                    if (case exp of Extract(LoadArgument a) => n = a | _ => false)
                    then ()
                    else Array.update(argMod, n, false);
                    n+1
                )
            in
                List.foldl testArg 0 argList;
                hasRecursiveCall := true;
                if isTail then () else allTail := false;
                List.foldl(fn ((e, _), n) => checkUse true (e, n, false)) (cl--3) argList
            end

        |   checkUse isMain (Eval{function, argList, ...}, cl, _) =
                checkUse isMain (function, List.foldl(fn ((e, _), n) => checkUse isMain (e, n, false)) (cl--2) argList, false)

        |   checkUse isMain (Cond(i, t, e), cl, isTail) =
                checkUse isMain (i, checkUse isMain (t, checkUse isMain (e, cl -- 2, isTail), isTail), false)
        |   checkUse isMain (BeginLoop { loop, arguments, ...}, cl, _) =
                checkUse isMain (loop, List.foldl (fn (({value, ...}, _), n) => checkUse isMain (value, n, false)) cl arguments, false)
        |   checkUse isMain (Loop args, cl, _) = List.foldl(fn ((e, _), n) => checkUse isMain (e, n, false)) cl args
        |   checkUse isMain (Raise c, cl, _) = checkUse isMain (c, cl -- 1, false)
        |   checkUse _      (Ldexc, cl, _) = cl -- 1
        |   checkUse isMain (Handle {exp, handler}, cl, isTail) =
                checkUse isMain (exp, checkUse isMain (handler, cl, isTail), false)
        |   checkUse isMain (Tuple{ fields, ...}, cl, _) = checkUseList isMain (fields, cl)

        |   checkUse isMain (SetContainer{container, tuple = Tuple { fields, ...}, ...}, cl, _) =
                (* This can be optimised *)
                checkUse isMain (container, checkUseList isMain (fields, cl), false)
        |   checkUse isMain (SetContainer{container, tuple, filter}, cl, _) =
                checkUse isMain (container, checkUse isMain (tuple, cl -- (BoolVector.length filter), false), false)

        |   checkUse isMain (TagTest{test, ...}, cl, _) = checkUse isMain (test, cl -- 1, false)
        
        and checkUseList isMain (elems, cl) =
            List.foldl(fn (e, n) => checkUse isMain (e, n, false)) cl elems
        
        val costLeft = checkUse true (function, maxInlineSize, true)
    in
        if costLeft = 0
        then TooBig
        else if not (! hasRecursiveCall) 
        then NonRecursive
        else if ! allTail then TailRecursive(Array.vector argMod)
        else NonTailRecursive(Array.vector argMod)
    end

    (* Turn a list of fields to use into a filter for SetContainer. *)
    fun fieldsToFilter useList =
    let
        val maxDest = List.foldl Int.max ~1 useList
        val fields = BoolArray.array(maxDest+1, false)
        val _ = List.app(fn n => BoolArray.update(fields, n, true)) useList
    in
        BoolArray.vector fields
    end


    (* When transforming code we only process one level and do not descend into sub-functions. *)
    local
        fun deExtract(Extract l) = l | deExtract _ = raise Misc.InternalError "deExtract"
        fun onlyFunction repEntry (Lambda{ body, isInline, name, closure, argTypes, resultType, localCount, recUse }) =
            SOME(
                Lambda {
                    body = body, isInline = isInline, name = name,
                    closure = map (deExtract o mapCodetree repEntry o Extract) closure,
                    argTypes = argTypes, resultType = resultType, localCount = localCount,
                    recUse = recUse
                }
            )
        |   onlyFunction repEntry code = repEntry code
    in
        fun mapFunctionCode repEntry = mapCodetree (onlyFunction repEntry)
    end

    local
        (* This transforms the body of a "small" recursive function replacing any reference
           to the arguments by the appropriate entry and the recursive calls themselves
           by either a Loop or a recursive call. *)
        fun mapCodeForFunctionRewriting(code, argMap, modVec, transformCall) =
        let
            fun repEntry(Extract(LoadArgument n)) = SOME(Extract(Vector.sub(argMap, n)))
            |   repEntry(Eval { function = Extract LoadRecursive, argList, resultType }) =
                let
                    (* Filter arguments to include only those that are changed and map any values we pass.
                       They may include references to the parameters. *)
                    fun mapArg((arg, argT)::rest, n) =
                        if Vector.sub(modVec, n) then mapArg(rest, n+1)
                        else (mapCode arg, argT) :: mapArg(rest, n+1)
                    |   mapArg([], _) = []
                in
                    SOME(transformCall(mapArg(argList, 0), resultType))
                end
            |   repEntry _ = NONE
        
            and mapCode code = mapFunctionCode repEntry code
        in
            mapCode code
        end
    in
        (* If we have a tail recursive function we can replace the tail calls
           by a loop.  modVec indicates the arguments that have not changed. *)
        fun replaceTailRecursiveWithLoop(body, argTypes, modVec, nextAddress) =
        let
            (* We need to create local bindings for arguments that will change.
               Those that do not can be reused. *)
            local
                fun mapArgs((argT, use):: rest, n, decs, mapList) =
                    if Vector.sub(modVec, n)
                    then mapArgs (rest, n+1, decs, LoadArgument n :: mapList)
                    else
                    let
                        val na = ! nextAddress before nextAddress := !nextAddress + 1
                    in
                        mapArgs (rest, n+1, ({addr = na, value = mkLoadArgument n, use=use}, argT) :: decs, LoadLocal na :: mapList)
                    end
                |   mapArgs([], _, decs, mapList) = (List.rev decs, List.rev mapList)
                val (decs, mapList) = mapArgs(argTypes, 0, [], [])
            in
                val argMap = Vector.fromList mapList
                val loopArgs = decs
            end
        
        in
            BeginLoop { arguments = loopArgs, loop = mapCodeForFunctionRewriting(body, argMap, modVec, fn (l, _) => Loop l) }
        end

        (* If we have a small recursive function where some arguments are passed
           through unchanged we can transform it by extracting the
           stable arguments and only passing the changing arguments.  The
           advantage is that this allows the stable arguments to be inserted
           inline which is important if they are functions. The canonical
           example is List.map. *)
        fun liftRecursiveFunction(body, argTypes, modVec, closureSize, name, resultType, localCount) =
        let
            local
                fun getArgs((argType, use)::rest, nArg, clCount, argCount, stable, change, mapList) =
                    let
                        (* This is the argument from the outer function.  It is either added
                           to the closure or passed to the inner function. *)
                        val argN = LoadArgument nArg
                    in
                        if Vector.sub(modVec, nArg)
                        then getArgs(rest, nArg+1, clCount+1, argCount,
                                    argN :: stable, change, LoadClosure clCount :: mapList)
                        else getArgs(rest, nArg+1, clCount, argCount+1,
                                    stable, (Extract argN, argType, use) :: change, LoadArgument argCount :: mapList)
                    end
                |   getArgs([], _, _, _, stable, change, mapList) =
                        (List.rev stable, List.rev change, List.rev mapList)
            in
                (* The stable args go into the closure.  The changeable args are passed in. *)
                val (stableArgs, changeArgsAndTypes, mapList) =
                    getArgs(argTypes, 0, closureSize, 0, [], [], [])
                val argMap = Vector.fromList mapList
            end

            val subFunction =
                Lambda {
                    body = mapCodeForFunctionRewriting(body, argMap, modVec, 
                            fn (l, t) => Eval {
                                function = Extract LoadRecursive, argList = l, resultType = t
                            }),
                    isInline = NonInline, (* Don't inline this function. *)
                    name = name ^ "()",
                    closure = List.tabulate(closureSize, fn n => LoadClosure n) @ stableArgs,
                    argTypes = List.map (fn (_, t, u) => (t, u)) changeArgsAndTypes,
                    resultType = resultType, localCount = localCount, recUse = [UseGeneral]
                }
        in
            Eval {
                function = subFunction,
                argList = map (fn (c, t, _) => (c, t)) changeArgsAndTypes,
                resultType = resultType
            }
        end
    end

    (* If the function arguments are used in a way that could be optimised the
       data structure represents it. *)
    datatype functionArgPattern =
        ArgPattTuple of { size: int, allConst: bool, fromFields: bool }
        (* ArgPattCurry is a list, one per level of application, of a
           list, one per argument of the pattern for that argument. *)
    |   ArgPattCurry of functionArgPattern list list * functionArgPattern
    |   ArgPattSimple


    (* Returns ArgPattCurry even if it is just a single application. *)
    local
        (* Control how we check for side-effects. *)
        datatype curryControl =
            CurryNoCheck | CurryCheck | CurryReorderable

        local
            open Address
        in
            (* Return the width of a tuple.  Returns 1 for non-tuples including
               datatypes where different variants could have different widths.
               Also returns a flag indicating if the value came from a constant.
               Constants are already tupled so there's no advantage in untupling
               them unless there are other non-constant arguments as well. *)
            fun findTuple(Tuple{fields, isVariant=false}) = (List.length fields, false)
            |   findTuple(Constnt(w, _)) =
                    if isShort w orelse flags (toAddress w) <> F_words then (1, false)
                    else (Word.toInt(length (toAddress w)), true)
            |   findTuple(Extract _) = (1, false) (* TODO: record this for variables *)
            |   findTuple(Cond(_, t, e)) =
                    let
                        val (tl, tc) = findTuple t
                        and (el, ec) = findTuple e
                    in
                        if tl = el then (tl, tc andalso ec) else (1, false)
                    end
            |   findTuple(Newenv(_, e)) = findTuple e
            |   findTuple _ = (1, false)
        end

        fun useToPattern _ [] = ArgPattSimple
        |   useToPattern checkCurry (hd::tl) =
            let
                (* Construct a possible pattern from the head. *)
                val p1 =
                    case hd of
                        UseApply(resl, arguments) =>
                            let
                                (* If the result is also curried extend the list. *)
                                val subCheck =
                                    case checkCurry of CurryCheck => CurryReorderable | c => c
                                val (resultPatts, resultResult) =
                                    case useToPattern subCheck resl of
                                        ArgPattCurry l => l
                                    |   tupleOrSimple => ([], tupleOrSimple)
                                fun mapArg c =
                                let
                                    val (n, f) = findTuple c
                                in
                                    if n <= 1
                                    then ArgPattSimple else ArgPattTuple{size=n, allConst=f, fromFields=false}
                                end
                                
                                val thisArg = map mapArg arguments
                            in
                                (* If we have an argument that is a curried function we
                                   can safely apply it to the first argument even if that
                                   has a side-effect but we can't uncurry further than that
                                   because the behaviour could rely on a side-effect of the
                                   first application. *)
                                if checkCurry = CurryReorderable
                                    andalso List.exists(not o reorderable) arguments
                                then ArgPattSimple
                                else ArgPattCurry(thisArg :: resultPatts, resultResult)
                            end
                    |   UseField (n, _) => ArgPattTuple{size=n+1, allConst=false, fromFields=true}
                    |   _ => ArgPattSimple

                fun mergePattern(ArgPattCurry(l1, r1), ArgPattCurry(l2, r2)) =
                    let
                        (* Each argument list should be the same length.
                           The length here is the number of arguments
                           provided to this application. *)
                        fun mergeArgLists(al1, al2) =
                            ListPair.mapEq mergePattern (al1, al2)
                        (* The currying lists could be different lengths
                           because some applications could only partially
                           apply it.  It is essential not to assume more
                           currying than the minimum so we stop with the
                           shorter. *)
                        val prefix = ListPair.map mergeArgLists (l1, l2)
                    in
                        if null prefix then ArgPattSimple else ArgPattCurry(prefix, mergePattern(r1, r2))
                    end
                    
                |   mergePattern(ArgPattTuple{size=n1, allConst=c1, fromFields=f1}, ArgPattTuple{size=n2, allConst=c2, fromFields=f2}) =
                        (* If the tuples are different sizes we can't use a tuple.
                           Unlike currying it would be safe to assume tupling where
                           there isn't (unless the function is actually polymorphic). *)
                        if n1 = n2 orelse (f1 andalso f2)
                        then ArgPattTuple{size=Int.max(n1, n2), allConst=c1 andalso c2, fromFields = f1 andalso f2}
                        else ArgPattSimple

                |   mergePattern _ = ArgPattSimple
            in
                case tl of
                    [] => p1
                |   tl => mergePattern(p1, useToPattern checkCurry tl)
            end

        (* If the result is just a function where all the arguments are simple
           it's not actually curried. *)
        fun usageToPattern checkCurry use =
            case useToPattern checkCurry use of
            (*    a as ArgPattCurry [s] =>
                    if List.all(fn ArgPattSimple => true | _ => false) s
                    then ArgPattSimple
                    else a
            |*)   patt => patt
    in
        (* Decurrying involves reordering (f exp1) exp2 into code
           where any effects of evaluating exp2 are done before the
           application.  That's only safe if either (f exp1) or exp2 have
           no side-effects and do not depend on references.
           In the case of the function body we can check that the body does
           not depend on any references (typically it's a lambda) but for
           function arguments we have to check how it is applied. *)
        val usageForFunctionBody = usageToPattern CurryNoCheck
        and usageForFunctionArg  = usageToPattern CurryCheck
    end

    (* If the usage indicates that the body of the function should be transformed
       these do the transformation.  It is possible that each of these cases could
       apply and it would be possible to merge them all.  For the moment keep them
       separate.  If another of the cases applies this will be re-entered on a
       subsequent pass. *)
    fun detupleResult({ argTypes, name, resultType, closure, isInline, localCount, body, ...}: lambdaForm , size, makeAddress) =
        (* The function returns a tuple or at least the uses of the function take apart a tuple.
           Transform it to take a container as an argument and put the result in there. *)
        let
            local
                fun mapArg f n ((t, _) :: tl) = (Extract(f n), t) :: mapArg f (n+1) tl
                |   mapArg _ _ [] = []
            in
                fun mapArgs f l = mapArg f 0 l
            end
            val mainAddress = makeAddress() and shimAddress = makeAddress()

            (* The main function performs the previous computation but puts the result into
               the container.  We need to replace any recursive references with calls to the
               shim.*)
            local
                val recEntry = LoadClosure(List.length closure)

                fun doMap(Extract LoadRecursive) = SOME(Extract recEntry)
                |   doMap _ = NONE
            in
                val transBody = mapFunctionCode doMap body
            end

            (* The size of the container is the smallest necessary to hold the fields
               actually required. *)
            local
                val containerArg = Extract(LoadArgument(List.length argTypes))
                val filter = BoolVector.tabulate(size, fn _ => true)
                val newBody =
                    SetContainer{container = containerArg, tuple = transBody, filter=filter }
                val mainLambda: lambdaForm =
                    {
                        body = newBody, name = name, resultType=GeneralType,
                        argTypes=argTypes @ [(GeneralType, [])],
                        closure=closure @ [LoadLocal shimAddress],
                        localCount=localCount + 1, isInline=isInline,
                        recUse = [UseGeneral]
                    }
            in
                val mainFunction = (mainAddress, mainLambda)
            end

            (* The shim function creates a container, passes it to the main function and then
               builds a tuple from the container. *)
            val shimBody =
                mkEnv(
                    [Container{addr = 0, use = [], size = size,
                        setter= Eval {
                                function = Extract(LoadClosure 0),
                                argList = mapArgs LoadArgument argTypes @ [(Extract(LoadLocal 0), GeneralType)],
                                resultType = GeneralType
                            }
                        }
                    ],
                    mkTupleFromContainer(0, size)
                    )
            val shimLambda =
                { body = shimBody, name = name, argTypes = argTypes, closure = [LoadLocal mainAddress],
                  resultType = resultType, isInline = Inline, localCount = 1, recUse = [UseGeneral] }
            val shimFunction = (shimAddress, shimLambda)
         in
            (shimLambda, [mainFunction, shimFunction])
        end

    fun transformFunctionArgs({ argTypes, name, resultType, closure, isInline, localCount, body, ...} , usage, makeAddress) =
        (* Not curried - just a single argument. *)
        let
            (* We need to construct an inline "shim" function that
               has the same calling pattern as the original.  This simply
               calls the transformed main function.
               We need to construct the arguments to call the transformed
               main function.  That needs, for example, to unpack tuples
               and repack argument functions.
               We need to produce an argument map to transform the main
               function.  This needs, for example, to pack the arguments
               into tuples.  Then when the code is run through the simplifier
               the tuples will be optimised away.  *)
            val localCounter = ref localCount

            fun mapPattern(ArgPattTuple{size=width, allConst=false, ...} :: patts, n, m) =
                let
                    val (decs, args, mapList) = mapPattern(patts, n+1, m+width)
                    val newAddr = ! localCounter before localCounter := ! localCounter + 1
                    val fields = List.tabulate(width, fn r => mkLoadArgument(m+r))
                    val thisDec = Declar { addr = newAddr, use = [], value = mkTuple fields }
                    (* Arguments for the call *)
                    val thisArg = List.tabulate(width, fn p => mkInd(p, mkLoadArgument n))
                in
                    (thisDec :: decs, thisArg @ args, LoadLocal newAddr :: mapList)
                end

            |   mapPattern(ArgPattCurry(currying, ArgPattTuple{allConst=false, size, ...}) :: patts, n, m) =
                (* It's a function that returns a tuple. *)
                let
                    val (thisDec, thisArg, thisMap) =
                        transformFunctionArgument(currying, [LoadArgument m], [LoadArgument n], SOME size)
                    val (decs, args, mapList) = mapPattern(patts, n+1, m+1)
                in
                    (thisDec :: decs, thisArg :: args, thisMap :: mapList)
                end

            |   mapPattern(ArgPattCurry(currying as firstArgSet :: _, _) :: patts, n, m) =
                (* Transform it if it's curried or if there is a tuple in the first arg. *)
                if List.length currying >= 2 orelse
                   List.exists(fn ArgPattTuple{allConst=false, ...} => true | _ => false) firstArgSet
                then
                let
                    val (thisDec, thisArg, thisMap) =
                        transformFunctionArgument(currying, [LoadArgument m], [LoadArgument n], NONE)
                    val (decs, args, mapList) = mapPattern(patts, n+1, m+1)
                in
                    (thisDec :: decs, thisArg :: args, thisMap :: mapList)
                end
                else
                let
                    val (decs, args, mapList) = mapPattern(patts, n+1, m+1)
                in
                    (decs, Extract(LoadArgument n) :: args, LoadArgument m :: mapList)
                end

            |   mapPattern(_ :: patts, n, m) =
                let
                    val (decs, args, mapList) = mapPattern(patts, n+1, m+1)
                in
                    (decs, Extract(LoadArgument n) :: args, LoadArgument m :: mapList)
                end

            |   mapPattern([], _, _) = ([], [], [])

            and transformFunctionArgument(argumentArgs, loadPack, loadThisArg, resTupleOpt) =
            let
                (* We have a function that takes a series of curried argument.
                   Change that so that the function takes a list of arguments. *)
                val newAddr = ! localCounter before localCounter := ! localCounter + 1
                (* In the main function we are expecting to call the argument in a curried
                   fashion.  We need to construct a function that packages up the
                   arguments and, when all of them have been provided, calls the actual
                   argument. *)
                val testCount = ref 0
                local
                    fun curryPack([], fnclosure) =
                        let
                            (* We're ready to call the function.  We now need to unpack any
                               tupled arguments. *)
                            fun mapArgs(c :: ctl, args) =
                            let
                                fun mapArg([], args) = mapArgs(ctl, args)
                                |   mapArg(ArgPattTuple{size=width, allConst=false, ...} :: patts, arg :: argctl) =
                                        List.tabulate(width, fn p => (mkInd(p, Extract arg), GeneralType)) @
                                            mapArg(patts, argctl)
                                |   mapArg(_ :: patts, arg :: argctl) =
                                        (Extract arg, GeneralType) :: mapArg(patts, argctl)
                                |   mapArg(_, []) = raise InternalError "mapArgs: mismatch"
                            in
                                mapArg(c, args)
                            end
                            |   mapArgs _ = []
                            val argList = mapArgs(argumentArgs, tl fnclosure)
                        in
                            case resTupleOpt of
                                NONE =>
                                    ( testCount := List.length argList;
                                    Eval { function = Extract(hd fnclosure), resultType = GeneralType,
                                            argList = argList }
                                    )
                            |   SOME size =>
                                    (* We need a container here for the result. *)
                                    (testCount := List.length argList + 1;
                                    mkEnv(
                                        [
                                            Container{addr=0, size=size, use=[UseGeneral], setter=
                                                Eval { function = Extract(hd fnclosure), resultType = GeneralType,
                                                    argList = argList @ [(mkLoadLocal 0, GeneralType)] }
                                            }
                                        ],
                                        mkTupleFromContainer(0, size)
                                    )
                                    )
                        end
                    |   curryPack(hd :: tl, fnclosure) =
                        let
                            val nArgs = List.length hd
                            (* If this is the last then we need to include the container if required. *)
                            val needContainer = case (tl, resTupleOpt) of ([], SOME _) => true | _ => false
                        in
                            Lambda { closure = fnclosure,
                                isInline = Inline, name = name ^ "-P", resultType = GeneralType,
                                argTypes = List.tabulate(nArgs, fn _ => (GeneralType, [UseGeneral])),
                                localCount = if needContainer then 1 else 0, recUse = [],
                                body = curryPack(tl,
                                            (* The closure for the next level is the current closure
                                               together with all the arguments at this level. *)
                                            List.tabulate(List.length fnclosure, fn n => LoadClosure n) @
                                            List.tabulate(nArgs, LoadArgument))
                            }
                        end
                in
                    val packFn = curryPack(argumentArgs, loadPack)
                end
                val thisDec = Declar { addr = newAddr, use = [], value = packFn }
                fun argCount(ArgPattTuple{size=width, allConst=false, ...}, m) = width + m
                |   argCount(_, m) = m+1
                local
                    (* In the shim function, i.e. the inline function outside, we have
                       a lambda that will be called when the main function wants to
                       call its argument function.  This is provided with all the arguments
                       and so it has to call the actual argument, which is expected to be
                       curried, an argument at a time. *)
                    fun curryApply(hd :: tl, n, c) =
                        let
                            fun makeArgs(_, []) = []
                            |   makeArgs(q, ArgPattTuple{size=width, allConst=false, ...} :: args) =
                                    (mkTuple(List.tabulate(width, fn r => mkLoadArgument(r+q))), GeneralType) ::
                                         makeArgs(q+width, args)
                            |   makeArgs(q, _ :: args) =
                                    (mkLoadArgument q, GeneralType) :: makeArgs(q+1, args)
                            val args = makeArgs(n, hd)
                        in
                            curryApply(tl, n + List.foldl argCount 0 hd,
                                Eval{function=c, resultType = GeneralType, argList=args})
                        end
                    |   curryApply([], _, c) = c
                in
                    val thisBody = curryApply (argumentArgs, 0, mkLoadClosure 0)
                end
                local
                    (* We have one argument for each argument at each level of currying, or
                       where we've expanded a tuple, one argument for each field.
                       If the function is returning a tuple we have an extra argument for
                       the container. *)
                    val totalArgCount =
                        List.foldl(fn (c, n) => n + List.foldl argCount 0 c) 0 argumentArgs +
                        (case resTupleOpt of SOME _ => 1 | _ => 0)
                    val _ = totalArgCount = ! testCount orelse raise InternalError "bad"
                    val functionBody =
                        case resTupleOpt of
                            NONE => thisBody
                        |   SOME size => mkSetContainer(mkLoadArgument(totalArgCount-1), thisBody,
                                                    BoolVector.tabulate(size, fn _ => true))
                in
                    val thisArg =
                        Lambda {
                            closure = loadThisArg, isInline = Inline, name = name ^ "-E",
                            argTypes = List.tabulate(totalArgCount, fn _ => (GeneralType, [UseGeneral])),
                            resultType = GeneralType, localCount = 0, recUse = [UseGeneral], body = functionBody
                        }
                end
            in
                (thisDec, thisArg, LoadLocal newAddr)
            end

            val (extraBindings, transArgCode, argMapList) = mapPattern(usage, 0, 0)

            local
                (* Transform the body by replacing the arguments with the new arguments. *)
                val argMap = Vector.fromList argMapList
                (* If we have a recursive reference we have to replace it with a reference
                   to the shim. *)
                val recEntry = LoadClosure(List.length closure)

                fun doMap(Extract(LoadArgument n)) = SOME(Extract(Vector.sub(argMap, n)))
                |   doMap(Extract LoadRecursive) = SOME(Extract recEntry)
                |   doMap _ = NONE
            in
                val transBody = mapFunctionCode doMap body
            end

            local
                (* The argument types for the main function have the tuples expanded,  Functions
                   are not affected. *)
                fun expand(ArgPattTuple{size, allConst=false, ...}, _, r) = List.tabulate(size, fn _ => (GeneralType, [])) @ r
                |   expand(_, a, r) = a :: r
            in
                val transArgTypes = ListPair.foldrEq expand [] (usage, argTypes)
            end

            (* Add the type information to the argument code. *)
            val transArgs = ListPair.mapEq(fn (c, (t, _)) => (c, t)) (transArgCode, transArgTypes)

            val mainAddress = makeAddress() and shimAddress = makeAddress()
            val transLambda =
                {
                    body = mkEnv(extraBindings, transBody), name = name, argTypes = transArgTypes,
                    closure = closure @ [LoadLocal shimAddress], resultType = resultType, isInline = isInline,
                    localCount = ! localCounter, recUse = [UseGeneral]
                }

            (* Return the pair of functions. *)
            val mainFunction = (mainAddress, transLambda)
            val shimBody =
                Eval { function = Extract(LoadClosure 0), argList = transArgs, resultType = resultType }
            val shimLambda =
                { body = shimBody, name = name, argTypes = argTypes, closure = [LoadLocal mainAddress],
                  resultType = resultType, isInline = Inline, localCount = 0, recUse = [UseGeneral] }
            val shimFunction = (shimAddress, shimLambda)
            (* TODO:  We have two copies of the shim function here. *)
        in
            (shimLambda, [mainFunction, shimFunction])
        end

    fun decurryFunction(
            { argTypes, name, resultType, closure, isInline, localCount,
              body as Lambda { argTypes=subArgTypes, resultType=subResultType, ... } , ...}, makeAddress) =
        (* Curried - just unwind one level this time.  This case is normally dealt with by
           the front-end at least for fun bindings. *)
        let
            local
                fun mapArg f n ((t, _) :: tl) = (Extract(f n), t) :: mapArg f (n+1) tl
                |   mapArg _ _ [] = []
            in
                fun mapArgs f l = mapArg f 0 l
            end

            val mainAddress = makeAddress() and shimAddress = makeAddress()
            (* The main function calls the original body as a function.  The body
               is a lambda which will contain references to the outer arguments but
               because we're just adding arguments these will be as before. *)
            (* We have to transform any recursive references to point to the shim. *)
            local
                val recEntry = LoadClosure(List.length closure)

                fun doMap(Extract LoadRecursive) = SOME(Extract recEntry)
                |   doMap _ = NONE
            in
                val transBody = mapFunctionCode doMap body
            end

            val arg1Count = List.length argTypes
            val mainLambda =
                {
                    body =
                        Eval{ function = transBody, resultType = subResultType,
                            argList = mapArgs (fn n => LoadArgument(n+arg1Count)) subArgTypes
                        },
                    name = name, resultType = subResultType,
                    closure = closure @ [LoadLocal shimAddress], isInline = isInline, localCount = localCount,
                    argTypes = argTypes @ subArgTypes, recUse = [UseGeneral]
                }
            val mainFunction = (mainAddress, mainLambda)

            val shimInnerLambda =
                Lambda {
                    (* The inner shim closure contains the main function and the outer arguments. *)
                    closure = LoadClosure 0 :: List.tabulate(arg1Count, LoadArgument),
                    body = Eval {
                                function = Extract(LoadClosure 0),
                                resultType = resultType,
                                (* Calls main function with both sets of args. *)
                                argList = mapArgs (fn n => LoadClosure(n+1)) argTypes @
                                          mapArgs LoadArgument subArgTypes
                            },
                    name = name ^ "-", resultType = subResultType, localCount = 0, isInline = Inline,
                    argTypes = subArgTypes, recUse = [UseGeneral]
                }

            val shimOuterLambda =
                { body = shimInnerLambda, name = name, argTypes = argTypes, closure = [LoadLocal mainAddress],
                  resultType = resultType, isInline = Inline, localCount = 0, recUse = [UseGeneral] }
            val shimFunction = (shimAddress, shimOuterLambda)
        in
            (shimOuterLambda: lambdaForm, [mainFunction, shimFunction])
        end

    |   decurryFunction _ = raise InternalError "decurryFunction"

    (* Process a Lambda slightly differently in different contexts. *)
    datatype lambdaContext = LCNormal | LCRecursive | LCImmediateCall

    (* Transforming a lambda may result in producing auxiliary functions that are in
       general mutually recursive. *)
    fun mapLambdaResult([], lambda) = lambda
    |   mapLambdaResult(bindings, lambda) =
            mkEnv([RecDecs(map(fn(addr, lam) => {addr=addr, use=[], lambda=lam}) bindings)], lambda)

    fun optimise (context, use) (Lambda lambda) =
            SOME(mapLambdaResult(optLambda(context, use, lambda, LCNormal)))

    |   optimise (context, use) (Newenv(envDecs, envExp)) =
        let
            fun mapExp mapUse = mapCodetree (optimise(context, mapUse))

            fun mapbinding(Declar{value, addr, use}) = Declar{value=mapExp use value, addr=addr, use=use}
            |   mapbinding(RecDecs l) =
                let
                    fun mapRecDec({addr, lambda, use}, rest) =
                        case optLambda(context, use, lambda, LCRecursive) of
                            (bindings, Lambda lambdaRes) =>
                                (* Turn any bindings into extra mutually-recursive functions. *)
                                {addr=addr, use = use, lambda = lambdaRes } ::
                                    map (fn (addr, res) => {addr=addr, use=use, lambda=res }) bindings @ rest
                        |   _ => raise InternalError "mapbinding: not lambda"
                in
                    RecDecs(foldl mapRecDec [] l)
                end
            |   mapbinding(NullBinding exp) = NullBinding(mapExp [UseGeneral] exp)
            |   mapbinding(Container{addr, use, size, setter}) =
                    Container{addr=addr, use=use, size=size, setter = mapExp [UseGeneral] setter}
        in
            SOME(Newenv(map mapbinding envDecs, mapExp use envExp))
        end

        (* Immediate call to a function.  We may be able to expand this inline unless it
           is recursive. *)
    |   optimise (context, use) (Eval {function = Lambda lambda, argList, resultType}) =
        let
            val args = map (fn (c, t) => (optGeneral context c, t)) argList
            val argTuples = map #1 args
            val (bindings, newLambda) = optLambda(context, [UseApply(use, argTuples)], lambda, LCImmediateCall)
            val call = Eval { function=newLambda, argList=args, resultType = resultType }
        in
            SOME(mapLambdaResult(bindings, call))
        end

    |   optimise (context, use) (Eval {function, argList, resultType}) =
        (* If nothing else we need to ensure that "use" is correctly set on
           the function and arguments and we don't simply pass the original. *)
        let
            val args = map (fn (c, t) => (optGeneral context c, t)) argList
            val argTuples = map #1 args
        in
            SOME(
                Eval{
                    function= mapCodetree (optimise (context, [UseApply(use, argTuples)])) function,
                    argList=args, resultType = resultType
                })
        end

    |   optimise (context, use) (Indirect{base, offset, isVariant = false}) =
        SOME(Indirect{base = mapCodetree (optimise(context, [UseField(offset, use)])) base,
                      offset = offset, isVariant = false})

    |   optimise (context, use) (code as Cond _) =
        (* If the result of the if-then-else is always taken apart as fields
           then we are better off taking it apart further down and putting
           the fields into a container on the stack. *)
        if List.all(fn UseField _ => true | _ => false) use
        then SOME(optFields(code, context, use))
        else NONE

    |   optimise (context, use) (code as BeginLoop _) =
        (* If the result of the loop is taken apart we should push
           this down as well. *)
        if List.all(fn UseField _ => true | _ => false) use
        then SOME(optFields(code, context, use))
        else NONE

    |   optimise _ _ = NONE
    
    and optGeneral context exp = mapCodetree (optimise(context, [UseGeneral])) exp

    and optLambda(
            { debugArgs, reprocess, makeAddr, ... },
            contextUse,
            { body, name, argTypes, resultType, closure, localCount, isInline, recUse, ...},
            lambdaContext) : (int * lambdaForm) list * codetree =
    (*
        Optimisations on lambdas.
        1.  A lambda that simply calls another function with all its own arguments
            can be replaced by a reference to the function provided the "function"
            is a side-effect-free expression.
        2.  Don't attempt to optimise inline functions that are exported.
        3.  Transform lambdas that take tuples as arguments or are curried or where
            an argument is a function with tupled or curried arguments into a pair
            of an inline function with the original argument set and a new "main"
            function with register/stack arguments.
    *)
    let
        (* The overall use of the function is the context plus the recursive use. *)
        val use = contextUse @ recUse
        (* Check if it's a call to another function with all the original arguments.
           This is really wanted when we are passing this lambda as an argument to
           another function and really only when we have produced a shim function
           that has been inline expanded.  Otherwise this will be a "small" function
           and will be inline expanded when it's used. *)
        val replaceBody =
            case (body, lambdaContext = LCRecursive) of
                (Eval { function, argList, resultType=callresult }, false) =>
                let
                    fun argSequence((Extract(LoadArgument a), _) :: rest, b) = a = b andalso argSequence(rest, b+1)
                    |   argSequence([], _) = true
                    |   argSequence _ = false
        
                    val argumentsMatch =
                        argSequence(argList, 0) andalso 
                            ListPair.allEq(fn((_, a), (b, _)) => a = b) (argList, argTypes) andalso
                            callresult = resultType
                in
                    if not argumentsMatch
                    then NONE
                    else
                    case function of
                        (* This could be any function which has neither side-effects nor
                           depends on a reference nor depends on another argument but if
                           it has local variables they would have to be renumbered into
                           the surrounding scope.  In practice we're really only interested
                           in simple cases that arise as a result of using a "shim" function
                           created in the code below. *)
                        c as Constnt _ => SOME c
                    |   Extract(LoadClosure addr) => SOME(Extract(List.nth(closure, addr)))
                    |   _ => NONE
                end
            |   _ => NONE
    in
        case replaceBody of
            SOME c => ([], c)
        |   NONE =>
            if isInline = Inline andalso List.exists (fn UseExport => true | _ => false) use
            then
            let
                (* If it's inline any application of this will be optimised after
                   inline expansion.  We still apply any opimisations to the body
                   at this stage because we will compile and code-generate a version
                   for use if we want a "general" value. *)
                val addressAllocator = ref localCount
                val optContext =
                {
                    makeAddr = fn () => (! addressAllocator) before addressAllocator := ! addressAllocator + 1,
                    reprocess = reprocess,
                    debugArgs = debugArgs
                }
                val optBody = mapCodetree (optimise(optContext, [UseGeneral])) body
                val lambdaRes =
                    {
                        body = optBody,
                        isInline = isInline, name = name, closure = closure,
                        argTypes = argTypes, resultType = resultType, recUse = recUse,
                        localCount = !addressAllocator (* After optimising body. *)
                    }
            in
                ([], Lambda lambdaRes) 
            end
            else
            let
                (* Allocate any new addresses after the existing ones. *)
                val addressAllocator = ref localCount
                val optContext =
                {
                    makeAddr = fn () => (! addressAllocator) before addressAllocator := ! addressAllocator + 1,
                    reprocess = reprocess,
                    debugArgs = debugArgs
                }
                val optBody = mapCodetree (optimise(optContext, [UseGeneral])) body

                (* See if this should be expanded inline.  If we are calling the lambda
                   immediately we try to expand it unless maxInlineSize is zero.  We
                   may not be able to expand it if it is recursive. (It may have been
                   inside an inline function). *)
                val maxInlineSize = DEBUG.getParameter DEBUG.maxInlineSizeTag debugArgs
                val (inlineType, updatedBody, localCount) =
                    case evaluateInlining(optBody, List.length argTypes,
                            if maxInlineSize <> 0 andalso lambdaContext = LCImmediateCall
                            then 1000 else maxInlineSize) of
                        NonRecursive  => (Inline, optBody, ! addressAllocator)
                    |   TailRecursive bv =>
                            (Inline,
                                replaceTailRecursiveWithLoop(optBody, argTypes, bv, addressAllocator), ! addressAllocator)
                    |   NonTailRecursive bv =>
                            if Vector.exists (fn n => n) bv
                            then (Inline, 
                                    liftRecursiveFunction(
                                        optBody, argTypes, bv, List.length closure, name, resultType, !addressAllocator), 0)
                            else (NonInline, optBody, ! addressAllocator) (* All arguments have been modified *)
                    |   TooBig => (NonInline, optBody, ! addressAllocator)

                val lambda: lambdaForm =
                {
                    body = updatedBody, name = name, argTypes = argTypes, closure = closure,
                    resultType = resultType, isInline = inlineType, localCount = localCount,
                    recUse = recUse
                }

                (* See if it should be transformed.  We only do this if the function is not going
                   to be inlined.  If it is then there's no point because the transformation is
                   going to be done as part of the inling process.  Even if it's marked for
                   inlining we may not actually call the function and instead pass it as an
                   argument or return it as result but in that case transformation doesn't
                   achieve anything because we are going to pass the untransformed "shim"
                   function anyway. *)
                val (newLambda, bindings) =
                    if isInline = NonInline
                    then
                    let
                        val functionPattern =
                            case usageForFunctionBody use of
                                ArgPattCurry(arg1 :: arg2 :: _, res) =>
                                    (* The function is always called with at least two curried arguments.
                                       We can decurry the function if the body is applicative - typically
                                       if it's a lambda - but not if applying the body would have a
                                       side-effect.  We only do it one level at this stage.  If it's
                                       curried more than that we'll come here again. *)
                                    (* In order to get the types we restrict this to the case of
                                       a body that is a lambda. *)
                                    if (*reorderable body*) case body of Lambda _ => true | _ => false
                                    then ArgPattCurry([arg1, arg2], res)
                                    else ArgPattCurry([arg1], res)
                            |   usage => usage

                        val argPatterns = map (usageForFunctionArg o #2) argTypes

                        (* fullArgPattern is a list, one per level of currying, of a list, one per argument of
                           the patterns.  resultPattern is used to detect whether the result is a tuple that
                           is taken apart.  TODO: This only looks at the use and not at the body to see
                           if we're returning a tuple.  That is largely handled by the front-end but it
                           would be better to try to see if there is a tuple being created. *)
                        val (fullArgPattern, resultPattern) =
                            case functionPattern of
                                ArgPattCurry(hd :: rest, resPattern) =>
                                let
                                    (* Merge the applications of the function with the use of the arguments. *)
                                    fun merge(a as ArgPattTuple _, _) = a
                                    |   merge(_, argUse) = argUse
                                in
                                    ((ListPair.mapEq merge (hd, argPatterns)) :: rest, resPattern)
                                end
                            |   _ =>
                                (if List.exists (fn UseExport => true | _ => false) use
                                then [argPatterns]
                                else [], ArgPattSimple)
                    in
                        case (fullArgPattern, resultPattern) of
                            (_ :: _ :: _, _) => (* Curried *)
                                ( reprocess := true; decurryFunction(lambda, makeAddr))

                        |   (_, ArgPattTuple {size, ...}) => (* Result is a tuple *)
                                ( reprocess := true; detupleResult(lambda, size, makeAddr))

                        |   (first :: _, _) =>
                            let
                                fun checkArg (ArgPattTuple{allConst=false, ...}) = true
                                        (* Function has at least one tupled arg. *)
                                |   checkArg (ArgPattCurry(_, ArgPattTuple{allConst=false, ...})) = true
                                        (* Function has an arg that is a function that returns a tuple. *)
                                |   checkArg (ArgPattCurry(_ :: _ :: _, _)) = true
                                        (* Function has an arg that is a curried function. *)
                                |   checkArg (ArgPattCurry(firstArgSet :: _, _)) =
                                        (* Function has an arg that is a function that
                                           takes a tuple in its first argument set. *)
                                        List.exists(fn ArgPattTuple{allConst=false, ...} => true | _ => false) firstArgSet
                                |   checkArg _ = false
                            in
                                (* It isn't curried - look at the arguments. *)
                                if List.exists checkArg first
                                then ( reprocess := true; transformFunctionArgs(lambda, first, makeAddr) )
                                else (lambda, [])
                            end

                        |   _ => (lambda, [])
                    end
                    else (lambda, [])
            in
                (* If this is to be inlined but was not before we may need to reprocess. *)
                if #isInline newLambda = Inline andalso isInline = NonInline
                then reprocess := true
                else ();
                (bindings, Lambda newLambda)
            end
    end

    and optFields (code, context as { reprocess, makeAddr, ...}, use) =
    let
        (* We have an if-then-else or a loop whose result is only ever
           taken apart.  We push this down. *)
        (* Find the fields that are used.  Not all may be. *)
        local
            val maxField =
                List.foldl(fn (UseField(f, _), m) => Int.max(f, m) | (_, m) => m) 0 use
            val fieldUse = BoolArray.array(maxField+1, false)
            val _ =
                List.app(fn UseField(f, _) => BoolArray.update(fieldUse, f, true) | _ => ()) use
        in
            val maxField = maxField
            val useList = BoolArray.foldri (fn (i, true, l) => i :: l | (_, _, l) => l) [] fieldUse
        end

        fun pushContainer(Cond(ifpt, thenpt, elsept), leafFn) =
                Cond(ifpt, pushContainer(thenpt, leafFn), pushContainer(elsept, leafFn))

        |   pushContainer(Newenv(decs, exp), leafFn) =
                Newenv(decs, pushContainer(exp, leafFn))

        |   pushContainer(BeginLoop{loop, arguments}, leafFn) =
                BeginLoop{loop = pushContainer(loop, leafFn), arguments=arguments}

        |   pushContainer(l as Loop _, _) = l
                (* Within a BeginLoop only the non-Loop leaves return
                   values.  Loop entries go back to the BeginLoop so
                   these are unchanged. *)

        |   pushContainer(tuple, leafFn) = leafFn tuple (* Anything else. *)

        val () = reprocess := true;
    in
        case useList of
            [offset] => (* We only want a single field.  Push down an Indirect. *)
            let
                (* However the context still requires a tuple.  We need to
                   reconstruct one with unused fields set to zero.  They will
                   be filtered out later by the simplifier pass. *)
                val field =
                    optGeneral context (pushContainer(code, fn t => mkInd(offset, t)))
                fun mkFields n = if n = offset then field else CodeZero
            in
                Tuple{ fields = List.tabulate(offset+1, mkFields), isVariant = false }
            end

        |   _ =>
            let
                (* We require a container. *)
                val containerAddr = makeAddr()
                val width = List.length useList
                val loadContainer = Extract(LoadLocal containerAddr)

                fun setContainer tuple = (* At the leaf set the container. *)
                    SetContainer{container = loadContainer, tuple = tuple, filter = fieldsToFilter useList }

                val setCode = optGeneral context (pushContainer(code, setContainer))
                val makeContainer =
                    Container{addr=containerAddr, use=[], size=width, setter=setCode}
                (* The context requires a tuple of the original width.  We need
                   to add dummy fields where necessary. *)
                val container =
                    if width = maxField+1
                    then mkTupleFromContainer(containerAddr, width)
                    else
                    let
                        fun mkField(n, m, hd::tl) =
                            if n = hd 
                            then mkInd(m, loadContainer) :: mkField(n+1, m+1, tl)
                            else CodeZero :: mkField(n+1, m, hd::tl)
                        |   mkField _ = []
                    in
                        Tuple{fields = mkField(0, 0, useList), isVariant=false}
                    end
            in
                mkEnv([makeContainer], container)
            end
    end

    (* TODO: convert "(if a then b else c) (args)" into if a then b(args) else c(args).  This would
       allow for possible inlining and also passing information about call patterns. *)

    fun codetreeOptimiser(code, debugSwitches, numLocals) =
    let
        fun topLevel _ = raise InternalError "top level reached"

        fun processTree (code, nLocals, optAgain, count) =
        let
            (* First run the simplifier.  Among other things this does inline
               expansion and if it does any we at least need to run cleanProc
               on the code so it will have set simpAgain. *)
            val (simpCode, simpCount, simpAgain) = SIMPLIFIER.simplifier(code, nLocals)
        in
            if optAgain orelse simpAgain
            then
            let
                (* Check for looping at least during testing.*)
                val _ = count < 10 orelse raise InternalError "Too many passes"
                (* Identify usage information and remove redundant code. *)
                val printCodeTree      = DEBUG.getParameter DEBUG.codetreeTag debugSwitches
                and compilerOut        = PRETTY.getCompilerOutput debugSwitches
                val simpCode = SIMPLIFIER.specialToGeneral simpCode
                val () = if printCodeTree then compilerOut(PRETTY.PrettyString "Output of simplifier") else ()
                val () = if printCodeTree then compilerOut (BASECODETREE.pretty simpCode) else ()
                val preOptCode =
                    REMOVE_REDUNDANT.cleanProc(simpCode, [UseExport], topLevel, simpCount)
                (* Print the code with the use information before it goes into the optimiser. *)
                val () = if printCodeTree then compilerOut(PRETTY.PrettyString "Output of cleaner") else ()
                val () = if printCodeTree then compilerOut (BASECODETREE.pretty preOptCode) else ()

                val reprocess = ref false (* May be set in the optimiser *)
                (* Allocate any new addresses after the existing ones. *)
                val addressAllocator = ref simpCount
                fun makeAddr() =
                    (! addressAllocator) before addressAllocator := ! addressAllocator + 1
                val optContext =
                {
                    makeAddr = makeAddr,
                    reprocess = reprocess,
                    debugArgs = debugSwitches
                }
                (* Optimise the code, rewriting it as necessary. *)
                val optCode = mapCodetree (optimise(optContext, [UseExport])) preOptCode

                (* Print the code after the optimiser. *)
                val () = if printCodeTree then compilerOut(PRETTY.PrettyString "Output of optimiser") else ()
                val () = if printCodeTree then compilerOut (BASECODETREE.pretty optCode) else ()
            in
                (* Rerun the simplifier at least. *)
                processTree(optCode, ! addressAllocator, ! reprocess, count+1)
            end
            else (simpCode, simpCount) (* We're done *)
        end

        val (postOptCode, postOptCount) = processTree(code, numLocals, true (* Once at least *), 1)
        val (rGeneral, rDecs, rSpec) = postOptCode
    in
        { numLocals = postOptCount, general = rGeneral, bindings = rDecs, special = rSpec }
    end

    structure Sharing = struct type codetree = codetree and envSpecial = envSpecial and codeBinding = codeBinding end

end;
