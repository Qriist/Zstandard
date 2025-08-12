#Requires AutoHotkey v2.0
#Include <Zstandard>
#include <Aris/Qriist/Null> ; github:Qriist/Null@v1.0.0 --main Null.ahk
#include <Aris/Descolada/Misc> ; Descolada/Misc@59a6ba7
dllpath := A_ScriptDir "\bin\zstd.dll"
try FileDelete(A_ScriptDir "\results2.txt")

inFileArr := [
    A_ScriptDir "\test files\lichess_db_standard_rated_2013-12.pgn.zst",
    A_ScriptDir "\test files\lichess_db_standard_rated_2013-01.pgn.zst",
    "C:\Projects\lichess\lichess_db_standard_rated_2023-03.pgn.zst"
]
zstd := Zstandard(dllpath)
for k, v in inFileArr {
    inFilePath := v

    foundArr := []
    ObjSetCapacity(foundArr, 1000000000)

    inFile := FileOpen(inFilePath, "r")
    contextObj := zstd.CreateDecompressContext()

    zstd.SetDecompressInputBufferSize(contextObj, FileGetSize(inFilePath))
    zstd.SetDecompressOutputBufferSize(contextObj, FileGetSize(inFilePath))
    start := A_NowUTC
    prepend := ""
    loop {
        ret := zstd.StreamDecompress(contextObj, inFile)
        if Type(ret) = "Null"
            break
        retStr := prepend StrGet(ret, "UTF-8")
        prepend := ""

        ;prevent false line prepends, split by lines
        findN := InStr(retStr, "`n", , -1)
        if findN = 0 {
            prepend .= retStr
            continue
        }
        retStrLen := StrLen(retStr)
        prepend := SubStr(retStr, findN)
        regexArr := RegExMatchAll(retStr, 'm)\[Site "https:\/\/lichess\.org\/(.+)"]')

        if InStr(prepend, regexArr[-1][1])
            prepend := "", foundDupe := regexArr[-1][1]
        for k, v in regexArr
            foundArr.push(v[1])
    } until (contextObj["ZstAtEOF"] > 0)
    end := A_NowUTC
    diff := DateDiff(end, start, "seconds")
    ret := start "`n" end "`ndiff seconds: " diff "`nfound: " foundArr.Length
    FileAppend(ret "`n", A_ScriptDir "\results2.txt")
    zstd.DestroyDecompressContext(contextObj)
}
