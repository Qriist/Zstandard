#Requires AutoHotkey v2.0.18+
class Zstandard {
    
    __New(dllpath) {
        this.dllpath := dllpath
        this.dllhandle := DllCall("LoadLibrary", "Str", dllpath, "Ptr")
        this.contextMap := Map()
        this.struct := Zstandard._struct()
    }

    SimpleDecompress(input,maxBufferSize := 100 * 1024 * 1024){        
        switch Type(input){
            case "File":
                buf := Buffer(input.length)
                input.Seek(0)
                input.RawRead(buf)
            case "Buffer":
                buf := input
        }

        outBuf := Buffer(maxBufferSize)
        realBufferSize := this.ZSTD_decompress(outBuf,outBuf.Size,buf,buf.size)
        outBuf.size := realBufferSize 
        return outBuf
    }
    CreateDecompressContext(outDataSize?){
        context :=  this.ZSTD_createDCtx()
        contextObj := this.contextMap[context] := Map()
        contextObj["context"] := context
        contextObj["ReadLineArr"] := []
        contextObj["ReadLine"] := ""
        contextObj["ReadLinePrepend"] := ""
        this.SetDecompressInputBufferSize(contextObj)
        this.SetDecompressOutputBufferSize(contextObj,outDataSize?)
        return contextObj
    }
    DestroyDecompressContext(contextObj){
        context := contextObj["context"]
        this.ZSTD_freeDStream(context)
        this.contextMap.Delete(context)
    }
    SetDecompressInputBufferSize(contextObj, inBufSize := 8 * 1024 * 1024){
        ;this is how much compressed data to feed to zstd at once
        contextObj["inBufSize"] := inBufSize
    }
    SetDecompressOutputBufferSize(contextObj, outDataSize := 8 * 1024 * 1024){
        ;this is the maximum size of the returned uncompressed data buffer
        contextObj["outDataSize"] := outDataSize
        contextObj["outData"] := d := Buffer(outDataSize)
        contextObj["outStruct"] := s := Buffer(24,0)
        NumPut("Ptr", d.Ptr, "UInt64", d.Size, "UInt64", 0, s)
    }


    StreamDecompress(contextObj, inSource) {
        ; Init context for file source
        if (Type(inSource) = "File") {
            if !contextObj.Has("inStruct") {
                contextObj["inBuf"] := Buffer(Min(contextObj["inBufSize"], inSource.Length))
                contextObj["inStruct"] := Buffer(24, 0)
                NumPut("Ptr", contextObj["inBuf"].Ptr, "UInt64", 0, "UInt64", 0, contextObj["inStruct"])

                contextObj["inData"] := inSource
                contextObj["inDataPos"] := 0
                contextObj["ZstAtEOF"] := false
            }
        }

        ; Ensure output struct exists
        if !contextObj.Has("outStruct") {
            contextObj["outData"] := Buffer(contextObj["outDataSize"], 0)
            contextObj["outStruct"] := Buffer(24, 0)
            NumPut("Ptr", contextObj["outData"].Ptr, "UInt64", contextObj["outDataSize"], "UInt64", 0, contextObj["outStruct"])
        }

        loop {
            ; Fill input if empty
            inPos  := NumGet(contextObj["inStruct"], 16, "UInt64")
            inSize := NumGet(contextObj["inStruct"], 8, "UInt64")
            if (inPos == inSize && !contextObj["ZstAtEOF"]) {
                contextObj["inData"].Seek(contextObj["inDataPos"])
                bytesRead := contextObj["inData"].RawRead(contextObj["inBuf"], contextObj["inBuf"].Size)
                contextObj["inDataPos"] := contextObj["inData"].Pos
                NumPut("UInt64", bytesRead, contextObj["inStruct"], 8)  ; size
                NumPut("UInt64", 0, contextObj["inStruct"], 16)         ; pos
                if (bytesRead = 0) {
                    contextObj["ZstAtEOF"] := true
                    return Null()
                }
            }

            ; Decompress
            ret := zstd.ZSTD_decompressStream(contextObj["context"], contextObj["outStruct"], contextObj["inStruct"])

            ; Get output size
            outPos := NumGet(contextObj["outStruct"], 16, "UInt64")
            if (outPos > 0) {
                outBuf := Buffer(outPos)
                DllCall("RtlMoveMemory", "ptr", outBuf.Ptr, "ptr", NumGet(contextObj["outStruct"], 0, "ptr"), "uptr", outPos)
                NumPut("UInt64", 0, contextObj["outStruct"], 16) ; reset pos
                return outBuf
            }
        }
        return ""
    }

    StreamDecompressByLine(contextObj,inSource){
        ;this is to simulate a FileObj.ReadLine() call with the compressed data
        
        ;Note that while this greatly simplifies the outer loop's code, 
        ;it is very slow if you intend to regex each return.

        ; pending returned lines
        If (contextObj["ReadLineArr"].length > 0){
            return contextObj["ReadLineArr"].Pop()
        }

        ;need to gather more decompressed data
        ret := this.StreamDecompress(contextObj, inSource)

        ;EOF
        If Type(ret) = "Null"
            return ret

        ;read from buffer
        retStr := contextObj["ReadLinePrepend"] StrGet(ret,"UTF-8")
        contextObj["ReadLinePrepend"] := ""

        ;prevent false line prepends, split by lines
        findN := InStr(retStr,"`n",,-1)
        If findN = 0 {
            contextObj["ReadLinePrepend"] .= retStr
            return ""
        }
        retStrLen := StrLen(retStr)
        init := StrSplit(retStr,"`n","r")
        If findN != retStrLen{
            contextObj["ReadLinePrepend"] := init.Pop()
        }

        ;slight capacity optimization
        if init.Length > ObjGetCapacity(contextObj["ReadLineArr"])
            ObjSetCapacity(contextObj["ReadLineArr"],init.Length)

        ; reverse the array order so returning is just a pop()
        loop init.Length
            contextObj["ReadLineArr"].push(init.Pop())

        return contextObj["ReadLineArr"].pop()
    }


    PrintObj(ObjectMapOrArray,depth := 5,indentLevel := ""){
        ; static self := StrSplit(A_ThisFunc,".")[StrSplit(A_ThisFunc,".").Length]
        list := ""
        For k,v in (Type(ObjectMapOrArray)!="Object"?ObjectMapOrArray:ObjectMapOrArray.OwnProps()){
            list .= indentLevel "[" k "]"
            Switch Type(v) {
                case "Map","Array","Object":
                    list .= "`n" this.PrintObj(v,depth-1,indentLevel  "    ")
                case "Buffer","LibQurl.Storage.MemBuffer":
                    list .= " => [BUFFER] "
                case "File","LibQurl.Storage.File":
                    list .= " => [FILE] "
                case "LibQurl.Storage.Magic":
                    list .= " => [MAGIC] "
                Default:
                    list .= " => " v
            }
            list := RTrim(list,"`r`n`r ") "`n"
        }
        return RTrim(list)
    }

    _getDllAddress(dllPath, dllfunction) {
        return DllCall("GetProcAddress", "Ptr", DllCall("GetModuleHandle", "Str", dllPath, "Ptr"), "AStr", dllfunction, "Ptr")
    }
    /* Version Numbers */
    ZSTD_versionNumber() {
        static ZSTD_versionNumber := this._getDllAddress(this.dllpath, "ZSTD_versionNumber")
        return DllCall(ZSTD_versionNumber
            , "UInt")
    }
    ZSTD_versionString() {
        static ZSTD_versionString := this._getDllAddress(this.dllpath, "ZSTD_versionString")
        return DllCall(ZSTD_versionString
            , "AStr")
    }

    /* Simple Core API */
    ZSTD_compress(dst, dstCapacity, src, srcSize, compressionLevel) {
        static ZSTD_compress := this._getDllAddress(this.dllpath, "ZSTD_compress")
        return DllCall(ZSTD_compress
            , "Ptr", dst
            , "UInt64", dstCapacity
            , "Ptr", src
            , "UInt64", srcSize
            , "Int", compressionLevel
            , "UInt64")
    }
    ZSTD_decompress(dst, dstCapacity, src, compressedSize) {
        static ZSTD_decompress := this._getDllAddress(this.dllpath, "ZSTD_decompress")
        return DllCall(ZSTD_decompress
            , "Ptr", dst
            , "UInt64", dstCapacity
            , "Ptr", src
            , "UInt64", compressedSize
            , "UInt64")
    }
    ZSTD_getFrameContentSize(src, srcSize) {
        static ZSTD_getFrameContentSize := this._getDllAddress(this.dllpath, "ZSTD_getFrameContentSize")
        return DllCall(ZSTD_getFrameContentSize
            , "Ptr", src
            , "UInt64", srcSize
            , "UInt64")
    }
    ZSTD_getDecompressedSize(src, srcSize) {
    ; [DEPRECATED] Use ZSTD_getFrameContentSize instead
        static ZSTD_getDecompressedSize := this._getDllAddress(this.dllpath, "ZSTD_getDecompressedSize")
        return DllCall(ZSTD_getDecompressedSize
            , "Ptr", src
            , "UInt64", srcSize
            , "UInt64")
    }
    ZSTD_findFrameCompressedSize(src, srcSize) {
        static ZSTD_findFrameCompressedSize := this._getDllAddress(this.dllpath, "ZSTD_findFrameCompressedSize")
        return DllCall(ZSTD_findFrameCompressedSize
            , "Ptr", src
            , "UInt64", srcSize
            , "UInt64")
    }

    /* Compression Helper Functions */
    ZSTD_compressBound(srcSize) {
        static ZSTD_compressBound := this._getDllAddress(this.dllpath, "ZSTD_compressBound")
        return DllCall(ZSTD_compressBound
            , "UInt64", srcSize
            , "UInt64")
    }

    /* Error Helper Functions */
    ZSTD_isError(result) {
        static ZSTD_isError := this._getDllAddress(this.dllpath, "ZSTD_isError")
        return DllCall(ZSTD_isError
            , "UInt64", result
            , "UInt")
    }
    ZSTD_getErrorCode(functionResult) {
        static ZSTD_getErrorCode := this._getDllAddress(this.dllpath, "ZSTD_getErrorCode")
        return DllCall(ZSTD_getErrorCode
            , "UInt64", functionResult
            , "Int")
    }

    ZSTD_getErrorName(result) {
        static ZSTD_getErrorName := this._getDllAddress(this.dllpath, "ZSTD_getErrorName")
        return DllCall(ZSTD_getErrorName
            , "UInt64", result
            , "AStr")
    }
    ZSTD_minCLevel() {
        static ZSTD_minCLevel := this._getDllAddress(this.dllpath, "ZSTD_minCLevel")
        return DllCall(ZSTD_minCLevel
            , "Int")
    }
    ZSTD_maxCLevel() {
        static ZSTD_maxCLevel := this._getDllAddress(this.dllpath, "ZSTD_maxCLevel")
        return DllCall(ZSTD_maxCLevel
            , "Int")
    }
    ZSTD_defaultCLevel() {
        static ZSTD_defaultCLevel := this._getDllAddress(this.dllpath, "ZSTD_defaultCLevel")
        return DllCall(ZSTD_defaultCLevel
            , "Int")
    }

    /* Explicit Context */
    ZSTD_createCCtx() {
        static ZSTD_createCCtx := this._getDllAddress(this.dllpath, "ZSTD_createCCtx")
        return DllCall(ZSTD_createCCtx
            , "Ptr")
    }
    ZSTD_freeCCtx(cctx) {
        static ZSTD_freeCCtx := this._getDllAddress(this.dllpath, "ZSTD_freeCCtx")
        return DllCall(ZSTD_freeCCtx
            , "Ptr", cctx
            , "UInt64")
    }
    ZSTD_compressCCtx(cctx, dst, dstCapacity, src, srcSize, compressionLevel) {
        static ZSTD_compressCCtx := this._getDllAddress(this.dllpath, "ZSTD_compressCCtx")
        return DllCall(ZSTD_compressCCtx
            , "Ptr", cctx
            , "Ptr", dst
            , "UInt64", dstCapacity
            , "Ptr", src
            , "UInt64", srcSize
            , "Int", compressionLevel
            , "UInt64")
    }
    ZSTD_createDCtx() {
        static ZSTD_createDCtx := this._getDllAddress(this.dllpath, "ZSTD_createDCtx")
        return DllCall(ZSTD_createDCtx
            , "Ptr")
    }
    ZSTD_freeDCtx(dctx) {
        static ZSTD_freeDCtx := this._getDllAddress(this.dllpath, "ZSTD_freeDCtx")
        return DllCall(ZSTD_freeDCtx
            , "Ptr", dctx
            , "UInt64")
    }
    ZSTD_decompressDCtx(dctx, dst, dstCapacity, src, srcSize) {
        static ZSTD_decompressDCtx := this._getDllAddress(this.dllpath, "ZSTD_decompressDCtx")
        return DllCall(ZSTD_decompressDCtx
            , "Ptr", dctx
            , "Ptr", dst
            , "UInt64", dstCapacity
            , "Ptr", src
            , "UInt64", srcSize
            , "UInt64")
    }

    /* Advanced Compression API (v1.4.0+) */
    ZSTD_cParam_getBounds(cParam) {
        static ZSTD_cParam_getBounds := this._getDllAddress(this.dllpath, "ZSTD_cParam_getBounds")
        return DllCall(ZSTD_cParam_getBounds
            , "Int", cParam
            , "Ptr")  ; returns a pointer to bounds struct (caller handles)
    }
    ZSTD_CCtx_setParameter(cctx, param, value) {
        static ZSTD_CCtx_setParameter := this._getDllAddress(this.dllpath, "ZSTD_CCtx_setParameter")
        return DllCall(ZSTD_CCtx_setParameter
            , "Ptr", cctx
            , "Int", param
            , "Int", value
            , "UInt64")
    }
    ZSTD_CCtx_setPledgedSrcSize(cctx, pledgedSrcSize) {
        static ZSTD_CCtx_setPledgedSrcSize := this._getDllAddress(this.dllpath, "ZSTD_CCtx_setPledgedSrcSize")
        return DllCall(ZSTD_CCtx_setPledgedSrcSize
            , "Ptr", cctx
            , "UInt64", pledgedSrcSize
            , "UInt64")
    }
    ZSTD_CCtx_reset(cctx, reset) {
        static ZSTD_CCtx_reset := this._getDllAddress(this.dllpath, "ZSTD_CCtx_reset")
        return DllCall(ZSTD_CCtx_reset
            , "Ptr", cctx
            , "Int", reset
            , "UInt64")
    }
    ZSTD_compress2(cctx, dst, dstCapacity, src, srcSize) {
        static ZSTD_compress2 := this._getDllAddress(this.dllpath, "ZSTD_compress2")
        return DllCall(ZSTD_compress2
            , "Ptr", cctx
            , "Ptr", dst
            , "UInt64", dstCapacity
            , "Ptr", src
            , "UInt64", srcSize
            , "UInt64")
    }

    /* Advanced Decompression API (v1.4.0+) */
    ZSTD_dParam_getBounds(dParam) {
        static ZSTD_dParam_getBounds := this._getDllAddress(this.dllpath, "ZSTD_dParam_getBounds")
        return DllCall(ZSTD_dParam_getBounds
            , "Int", dParam
            , "Ptr")  ; returns pointer to bounds struct
    }
    ZSTD_DCtx_setParameter(dctx, param, value) {
        static ZSTD_DCtx_setParameter := this._getDllAddress(this.dllpath, "ZSTD_DCtx_setParameter")
        return DllCall(ZSTD_DCtx_setParameter
            , "Ptr", dctx
            , "Int", param
            , "Int", value
            , "UInt64")
    }
    ZSTD_DCtx_reset(dctx, reset) {
        static ZSTD_DCtx_reset := this._getDllAddress(this.dllpath, "ZSTD_DCtx_reset")
        return DllCall(ZSTD_DCtx_reset
            , "Ptr", dctx
            , "Int", reset
            , "UInt64")
    }

    /* Streaming */
    ZSTD_createCStream() {
        static ZSTD_createCStream := this._getDllAddress(this.dllpath, "ZSTD_createCStream")
        return DllCall(ZSTD_createCStream
            , "Ptr")
    }
    ZSTD_freeCStream(zcs) {
        static ZSTD_freeCStream := this._getDllAddress(this.dllpath, "ZSTD_freeCStream")
        return DllCall(ZSTD_freeCStream
            , "Ptr", zcs
            , "UInt64")
    }
    ZSTD_compressStream2(cctx, output, input, endOp) {
        static ZSTD_compressStream2 := this._getDllAddress(this.dllpath, "ZSTD_compressStream2")
        return DllCall(ZSTD_compressStream2
            , "Ptr", cctx
            , "Ptr", output
            , "Ptr", input
            , "Int", endOp
            , "UInt64")
    }
    ZSTD_CStreamInSize() {
        static ZSTD_CStreamInSize := this._getDllAddress(this.dllpath, "ZSTD_CStreamInSize")
        return DllCall(ZSTD_CStreamInSize
            , "UInt64")
    }
    ZSTD_CStreamOutSize() {
        static ZSTD_CStreamOutSize := this._getDllAddress(this.dllpath, "ZSTD_CStreamOutSize")
        return DllCall(ZSTD_CStreamOutSize
            , "UInt64")
    }
    ZSTD_initCStream(zcs, compressionLevel) {
        static ZSTD_initCStream := this._getDllAddress(this.dllpath, "ZSTD_initCStream")
        return DllCall(ZSTD_initCStream
            , "Ptr", zcs
            , "Int", compressionLevel
            , "UInt64")
    }
    ZSTD_compressStream(zcs, output, input) {
        static ZSTD_compressStream := this._getDllAddress(this.dllpath, "ZSTD_compressStream")
        return DllCall(ZSTD_compressStream
            , "Ptr", zcs
            , "Ptr", output
            , "Ptr", input
            , "UInt64")
    }
    ZSTD_flushStream(zcs, output) {
        static ZSTD_flushStream := this._getDllAddress(this.dllpath, "ZSTD_flushStream")
        return DllCall(ZSTD_flushStream
            , "Ptr", zcs
            , "Ptr", output
            , "UInt64")
    }
    ZSTD_endStream(zcs, output) {
        static ZSTD_endStream := this._getDllAddress(this.dllpath, "ZSTD_endStream")
        return DllCall(ZSTD_endStream
            , "Ptr", zcs
            , "Ptr", output
            , "UInt64")
    }
    ZSTD_createDStream() {
        static ZSTD_createDStream := this._getDllAddress(this.dllpath, "ZSTD_createDStream")
        return DllCall(ZSTD_createDStream
            , "Ptr")
    }
    ZSTD_freeDStream(zds) {
        static ZSTD_freeDStream := this._getDllAddress(this.dllpath, "ZSTD_freeDStream")
        return DllCall(ZSTD_freeDStream
            , "Ptr", zds
            , "UInt64")
    }
    ZSTD_initDStream(zds) {
        static ZSTD_initDStream := this._getDllAddress(this.dllpath, "ZSTD_initDStream")
        return DllCall(ZSTD_initDStream
            , "Ptr", zds
            , "UInt64")
    }
    ZSTD_decompressStream(zds, output, input) {
        static ZSTD_decompressStream := this._getDllAddress(this.dllpath, "ZSTD_decompressStream")
        return DllCall(ZSTD_decompressStream
            , "Ptr", zds
            , "Ptr", output
            , "Ptr", input
            , "UInt64")
    }
    ZSTD_decompressStream_simpleArgs(dctx, dst, dstCapacity, dstPos, src, srcSize, srcPos) {
        static ZSTD_decompressStream_simpleArgs := this._getDllAddress(this.dllpath, "ZSTD_decompressStream_simpleArgs")
        return DllCall(ZSTD_decompressStream_simpleArgs
            , "Ptr", dctx
            , "Ptr", dst
            , "UInt64", dstCapacity
            , "Ptr", dstPos
            , "Ptr", src
            , "UInt64", srcSize
            , "Ptr", srcPos
            , "UInt64")
    }
    ZSTD_DStreamInSize() {
        static ZSTD_DStreamInSize := this._getDllAddress(this.dllpath, "ZSTD_DStreamInSize")
        return DllCall(ZSTD_DStreamInSize
            , "UInt64")
    }
    ZSTD_DStreamOutSize() {
        static ZSTD_DStreamOutSize := this._getDllAddress(this.dllpath, "ZSTD_DStreamOutSize")
        return DllCall(ZSTD_DStreamOutSize
            , "UInt64")
    }

    /* Simple Dictionary API */
    ZSTD_compress_usingDict(ctx, dst, dstCapacity, src, srcSize, dict, dictSize) {
        static ZSTD_compress_usingDict := this._getDllAddress(this.dllpath, "ZSTD_compress_usingDict")
        return DllCall(ZSTD_compress_usingDict
            , "Ptr", ctx
            , "Ptr", dst
            , "UInt64", dstCapacity
            , "Ptr", src
            , "UInt64", srcSize
            , "Ptr", dict
            , "UInt64", dictSize
            , "UInt64")
    }
    ZSTD_decompress_usingDict(dctx, dst, dstCapacity, src, srcSize, dict, dictSize) {
        static ZSTD_decompress_usingDict := this._getDllAddress(this.dllpath, "ZSTD_decompress_usingDict")
        return DllCall(ZSTD_decompress_usingDict
            , "Ptr", dctx
            , "Ptr", dst
            , "UInt64", dstCapacity
            , "Ptr", src
            , "UInt64", srcSize
            , "Ptr", dict
            , "UInt64", dictSize
            , "UInt64")
    }

    /* Bulk Processing Dictionary API */
    ZSTD_createCDict(dictBuffer, dictSize, compressionLevel) {
        static ZSTD_createCDict := this._getDllAddress(this.dllpath, "ZSTD_createCDict")
        return DllCall(ZSTD_createCDict
            , "Ptr", dictBuffer
            , "UInt64", dictSize
            , "Int", compressionLevel
            , "Ptr")
    }
    ZSTD_freeCDict(CDict) {
        static ZSTD_freeCDict := this._getDllAddress(this.dllpath, "ZSTD_freeCDict")
        return DllCall(ZSTD_freeCDict
            , "Ptr", CDict
            , "UInt64")
    }
    ZSTD_compress_usingCDict(cctx, dst, dstCapacity, src, srcSize, cdict) {
        static ZSTD_compress_usingCDict := this._getDllAddress(this.dllpath, "ZSTD_compress_usingCDict")
        return DllCall(ZSTD_compress_usingCDict
            , "Ptr", cctx
            , "Ptr", dst
            , "UInt64", dstCapacity
            , "Ptr", src
            , "UInt64", srcSize
            , "Ptr", cdict
            , "UInt64")
    }
    ZSTD_createDDict(dictBuffer, dictSize) {
        static ZSTD_createDDict := this._getDllAddress(this.dllpath, "ZSTD_createDDict")
        return DllCall(ZSTD_createDDict
            , "Ptr", dictBuffer
            , "UInt64", dictSize
            , "Ptr")
    }
    ZSTD_freeDDict(ddict) {
        static ZSTD_freeDDict := this._getDllAddress(this.dllpath, "ZSTD_freeDDict")
        return DllCall(ZSTD_freeDDict
            , "Ptr", ddict
            , "UInt64")
    }
    ZSTD_decompress_usingDDict(dctx, dst, dstCapacity, src, srcSize, ddict) {
        static ZSTD_decompress_usingDDict := this._getDllAddress(this.dllpath, "ZSTD_decompress_usingDDict")
        return DllCall(ZSTD_decompress_usingDDict
            , "Ptr", dctx
            , "Ptr", dst
            , "UInt64", dstCapacity
            , "Ptr", src
            , "UInt64", srcSize
            , "Ptr", ddict
            , "UInt64")
    }

    /* Dictionary Helper Functions */
    ZSTD_getDictID_fromDict(dict, dictSize) {
        static ZSTD_getDictID_fromDict := this._getDllAddress(this.dllpath, "ZSTD_getDictID_fromDict")
        return DllCall(ZSTD_getDictID_fromDict
            , "Ptr", dict
            , "UInt64", dictSize
            , "UInt")
    }
    ZSTD_getDictID_fromCDict(cdict) {
        static ZSTD_getDictID_fromCDict := this._getDllAddress(this.dllpath, "ZSTD_getDictID_fromCDict")
        return DllCall(ZSTD_getDictID_fromCDict
            , "Ptr", cdict
            , "UInt")
    }
    ZSTD_getDictID_fromDDict(ddict) {
        static ZSTD_getDictID_fromDDict := this._getDllAddress(this.dllpath, "ZSTD_getDictID_fromDDict")
        return DllCall(ZSTD_getDictID_fromDDict
            , "Ptr", ddict
            , "UInt")
    }
    ZSTD_getDictID_fromFrame(src, srcSize) {
        static ZSTD_getDictID_fromFrame := this._getDllAddress(this.dllpath, "ZSTD_getDictID_fromFrame")
        return DllCall(ZSTD_getDictID_fromFrame
            , "Ptr", src
            , "UInt64", srcSize
            , "UInt")
    }

    /* Advanced Dictionary & Prefix API (v1.4.0+) */
    ZSTD_CCtx_loadDictionary(cctx, dict, dictSize) {
        static ZSTD_CCtx_loadDictionary := this._getDllAddress(this.dllpath, "ZSTD_CCtx_loadDictionary")
        return DllCall(ZSTD_CCtx_loadDictionary
            , "Ptr", cctx
            , "Ptr", dict
            , "UInt64", dictSize
            , "UInt64")
    }
    ZSTD_CCtx_refCDict(cctx, cdict) {
        static ZSTD_CCtx_refCDict := this._getDllAddress(this.dllpath, "ZSTD_CCtx_refCDict")
        return DllCall(ZSTD_CCtx_refCDict
            , "Ptr", cctx
            , "Ptr", cdict
            , "UInt64")
    }
    ZSTD_CCtx_refPrefix(cctx, prefix, prefixSize) {
        static ZSTD_CCtx_refPrefix := this._getDllAddress(this.dllpath, "ZSTD_CCtx_refPrefix")
        return DllCall(ZSTD_CCtx_refPrefix
            , "Ptr", cctx
            , "Ptr", prefix
            , "UInt64", prefixSize
            , "UInt64")
    }
    ZSTD_DCtx_loadDictionary(dctx, dict, dictSize) {
        static ZSTD_DCtx_loadDictionary := this._getDllAddress(this.dllpath, "ZSTD_DCtx_loadDictionary")
        return DllCall(ZSTD_DCtx_loadDictionary
            , "Ptr", dctx
            , "Ptr", dict
            , "UInt64", dictSize
            , "UInt64")
    }
    ZSTD_DCtx_refDDict(dctx, ddict) {
        static ZSTD_DCtx_refDDict := this._getDllAddress(this.dllpath, "ZSTD_DCtx_refDDict")
        return DllCall(ZSTD_DCtx_refDDict
            , "Ptr", dctx
            , "Ptr", ddict
            , "UInt64")
    }
    ZSTD_DCtx_refPrefix(dctx, prefix, prefixSize) {
        static ZSTD_DCtx_refPrefix := this._getDllAddress(this.dllpath, "ZSTD_DCtx_refPrefix")
        return DllCall(ZSTD_DCtx_refPrefix
            , "Ptr", dctx
            , "Ptr", prefix
            , "UInt64", prefixSize
            , "UInt64")
    }
    ZSTD_sizeof_CCtx(cctx) {
        static ZSTD_sizeof_CCtx := this._getDllAddress(this.dllpath, "ZSTD_sizeof_CCtx")
        return DllCall(ZSTD_sizeof_CCtx
            , "Ptr", cctx
            , "UInt64")
    }
    ZSTD_sizeof_DCtx(dctx) {
        static ZSTD_sizeof_DCtx := this._getDllAddress(this.dllpath, "ZSTD_sizeof_DCtx")
        return DllCall(ZSTD_sizeof_DCtx
            , "Ptr", dctx
            , "UInt64")
    }
    ZSTD_sizeof_CStream(zcs) {
        static ZSTD_sizeof_CStream := this._getDllAddress(this.dllpath, "ZSTD_sizeof_CStream")
        return DllCall(ZSTD_sizeof_CStream
            , "Ptr", zcs
            , "UInt64")
    }
    ZSTD_sizeof_DStream(zds) {
        static ZSTD_sizeof_DStream := this._getDllAddress(this.dllpath, "ZSTD_sizeof_DStream")
        return DllCall(ZSTD_sizeof_DStream
            , "Ptr", zds
            , "UInt64")
    }
    ZSTD_sizeof_CDict(cdict) {
        static ZSTD_sizeof_CDict := this._getDllAddress(this.dllpath, "ZSTD_sizeof_CDict")
        return DllCall(ZSTD_sizeof_CDict
            , "Ptr", cdict
            , "UInt64")
    }
    ZSTD_sizeof_DDict(ddict) {
        static ZSTD_sizeof_DDict := this._getDllAddress(this.dllpath, "ZSTD_sizeof_DDict")
        return DllCall(ZSTD_sizeof_DDict
            , "Ptr", ddict
            , "UInt64")
    }
    
    /* Frame Header & Size Functions */
    ZSTD_findDecompressedSize(src, srcSize) {
        static ZSTD_findDecompressedSize := this._getDllAddress(this.dllpath, "ZSTD_findDecompressedSize")
        return DllCall(ZSTD_findDecompressedSize
            , "Ptr", src
            , "UInt64", srcSize
            , "UInt64")
    }
    
    class _struct{
        ZSTD_inBuffer_s(ptr?) {
            retObj := Map()
            retObj["ptr"]  := ptr
            retObj["src"]  := NumGet(ptr, 0, "Ptr")
            retObj["size"] := NumGet(ptr, A_PtrSize, "UPtr")
            retObj["pos"]  := NumGet(ptr, A_PtrSize * 2, "UPtr")
            return retObj
        }

        ZSTD_outBuffer_s(ptr?) {
            retObj := Map()
            retObj["ptr"]  := ptr
            retObj["dst"]  := NumGet(ptr, 0, "Ptr")
            retObj["size"] := NumGet(ptr, A_PtrSize, "UPtr")
            retObj["pos"]  := NumGet(ptr, A_PtrSize * 2, "UPtr")
            return retObj
        }
    }
}