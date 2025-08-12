#Requires AutoHotkey v2.0
#Include <Zstandard>
#include <Aris/Qriist/Null> ; github:Qriist/Null@v1.0.0 --main Null.ahk
#include <Aris/Descolada/Misc> ; Descolada/Misc@59a6ba7
dllpath := A_ScriptDir "\bin\zstd.dll"
foundArr := []
ObjSetCapacity(foundArr,1000000000)

inFilePath := A_ScriptDir "\test files\lichess_db_standard_rated_2013-01.pgn.zst"
; inFilePath := A_ScriptDir "\test files\lichess_db_standard_rated_2013-12.pgn.zst"
; inFilePath := "C:\Projects\lichess\lichess_db_standard_rated_2023-03.pgn.zst"

zstd := Zstandard(dllpath)
inFile := FileOpen(inFilePath,"r")


contextObj := zstd.CreateDecompressContext()
; zstd.SetDecompressInputBufferSize(contextObj,FileGetSize(inFilePath))
; zstd.SetDecompressOutputBufferSize(contextObj,FileGetSize(inFilePath))

start := A_NowUTC
prepend := ""
Loop {

    ret := zstd.StreamDecompress(contextObj, inFile)
    if Type(ret) = "Null"
        break
    ; MsgBox prepend
    retStr := prepend StrGet(ret,"UTF-8")
    prepend := ""
    ; MsgBox A_Clipboard := retStr
    ;prevent false line prepends, split by lines
    findN := InStr(retStr,"`n",,-1)
    If findN = 0 {
        prepend .= retStr
        continue
    }
    retStrLen := StrLen(retStr)
    prepend := SubStr(retStr,findN)
    regexArr := RegExMatchAll(retStr,'m)\[Site "https:\/\/lichess\.org\/(.+)"]')

    If InStr(prepend,regexArr[-1][1])
        prepend := "", foundDupe := regexArr[-1][1]
    for k,v in regexArr
        foundArr.push(v[1])
    ; running := foundArr.Length
}  until (contextObj["ZstAtEOF"] > 0)
end := A_NowUTC
diff := DateDiff(end,start,"seconds")
; msgbox ret := start "`n" end "`ndiff seconds: " diff "`nfound: " foundArr.Length
ret := start "`n" end "`ndiff seconds: " diff "`nfound: " foundArr.Length
try FileDelete(A_ScriptDir "\results.txt")
FileAppend(ret,A_ScriptDir "\results.txt")
; out := FileOpen(A_ScriptDir "\results2.txt","w")
; for k,v in foundArr
;     out.WriteLine(v)
; out.Close()