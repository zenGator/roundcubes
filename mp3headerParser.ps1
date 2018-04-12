#mp3HeaderParser
#20180401:zG

[CMDletBinding()]
#param ([Parameter(Mandatory=$true)][string]$inFile)
param ([string]$inFile = $pwd.Path +"\"+ 'test.mp3' ,
        [switch]$debugging ,
        [int]$skipto = 0,
        [string]$exceptions = $pwd.Path +"\"+ 'exceptions_log.txt',
        [string]$errors = $pwd.Path +"\"+ 'error_log.txt'
         )
$frameFlag=[system.Byte[]](0xFF,0xE0)

  #need a couple of lookups
     #BitRate Index:  2 MPEGversions x 3 layers x 15 valid bitrates
     #$brIndexTable [2] [3] [15]
     $brIndexTable =
         @( @(@(0,32,64,96,128,160,192,224,256,288,320,352,384,416,448), #V1,L1
                 @(0,32,48,56, 64, 80,96,112,128,160,192,224,256,320,384), #V1,L2
                 @(0,32,40,48, 56, 64, 80, 96,112,128,160,192,224,256,320))), #V1,L3
         @( @( @(0,32,48,56,64,80,96,112,128,144,160,176,192,224,256), #V2,L1
                 @(0,8,16,24,32,40,48,56,64,80,96,112,128,144,160), #V2,L2
                 @(0,8,16,24,32,40,48,56,64,80,96,112,128,144,160))), #V2,L3
        @( @( @(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0), #this block is fake for the invalid Version
              @(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0),
              @(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))),
        @( @( @(0,32,48,56,64,80,96,112,128,144,160,176,192,224,256), #V2.5,L1  Identical to the v2 block
                 @(0,8,16,24,32,40,48,56,64,80,96,112,128,144,160), #V2.5,L2
                 @(0,8,16,24,32,40,48,56,64,80,96,112,128,144,160))) #V2.5,L3


     #SamplingRate Index: 2 MPEG versions x 3 valid frequencies
     #$samplingTable [2] [3]
     $samplingTable =
         @(44100,48000,32000), #MPEG v1
         @(22050,24000,16000) #MPEG v2
     #for Mode extension (bits 27 & 28), when layer 1 or 2 (bits 14 & 15)
     $stereoModeTable = @("4 to 31","8 to 31","12 to 31","16 to 31") #L1,L2
     #emphasisTable  (bits 31,32 => 00000011 => 0x3 => 3 )
     $emphasisTable = @("none","50/15 ms","reserved","CCIT J.17")

$summary=@{}
$myOffset=0
if( $inFile.Substring(0,2) -eq '.\' ) {$inFile=$pwd.Path +"\"+$inFile }
try {
    if( $exceptions.Substring(0,2) -eq '.\' ) {$exceptions =$pwd.Path +"\"+$exceptions}
    write-verbose "writing exceptions to $exceptions"
    $exceptStream = [system.io.streamwriter] $exceptions
    if( $errors.Substring(0,2) -eq '.\' ) {$errors =$pwd.Path +"\"+$errors}
    write-verbose "writing errors to $errors"
    $errorLog = [system.io.streamwriter] $errors
    }
catch {
    write-host $_
    exit
    }


$lastelapsed=0
$calcdFrameLen=0
$lastCalcdFrameLen=0
$nextFrameHeaderPosn=0
$frameNumber=0
$eof=$false

write-Verbose ("processing " + $inFile )

$bytes=[System.IO.File]::ReadAllBytes($inFile)
Write-Verbose ("successfully read "+$bytes.Length+" from "+$inFile )
$startTime=(Get-date -Uformat %s)

while ($myOffset -lt ($bytes.Length-4)) {    #no need to go to the VERY end . . .
     DO {
#     $outStr="Status:  currently at frame #{0}, offset {1}" -f  $framenumber, $myOffset; Write-Host $outStr
         $buffer=$bytes[($myOffset++)..$myOffset]
#         $myOffset++
         if ($myOffset -ge ($bytes.Length - 4) ) {   #no need to go to the VERY end . . .
             Write-Debug "Quitting at end of file"
             $eof=$true
             break
             }
         } 
         until (($buffer[0] -eq 0xff) -and (($buffer[1] -band 0xe0) -eq 0xe0))  #looking for 11 ones
     if ($eof) {break}

#try {

     $currentFrameHeadStart=$myOffset - 1 
     $currentFrameHeadEnd=$myOffset + 2
     $currentDataStart= $currentFrameHeadStart + 4
     $possibleFrameHeader=$bytes[ $currentFrameHeadStart .. $currentFrameHeadEnd ]  #MP3 frame headers are 4 bytes, beginning 0b1111 1111 111x x...x

     #now that we have a possible header, let's see what the different attributes are:
     #reference https://www.mp3-tech.org/programmer/frame_header.html for the lookup
     #starting with the MPEG version ID (bits 12 & 13 => 00011000 => 0x18 => 24)
     $mpegVer = ($possibleFrameHeader[1] -band 0x18) -shr 3
     <#  00 - MPEG Version 2.5 (later extension of MPEG 2)
         01 - reserved
         10 - MPEG Version 2 (ISO/IEC 13818-3)
         11 - MPEG Version 1 (ISO/IEC 11172-3)
      #>
     switch ($mpegVer)
     {
         0 { $mpegVerStr = '2.5 (unofficial)' ; $validVer=$false }
         1 { $mpegVerStr = 'reserved' ; $validVer=$false }
         2 { $mpegVerStr = '2' ; $validVer=$true}
         3 { $mpegVerStr = '1' ; $validVer=$true}
     }
     if ($validVer -ne $true) {
        Write-Debug ("Found invalid header version @" + $currentFrameHeadStart )
    $outStr="@{0,10} (#{1,8})`t{2,8} value ({3,6}) is invalid; header: {4,12}`t=> {5}" -f $currentFrameHeadStart,($frameNumber + 1),"mpegVer", $mpegVer,[string]($possibleFrameHeader | ForEach-Object ToString X2),$mpegVerStr
    $exceptStream.WriteLine($outStr)
        continue
        }
     
         $dbgStr = "Possible header [{0}] at offset {1}, mpegVer: {2}" -f [string]($possibleFrameHeader | ForEach-Object ToString X2), $currentFrameHeadStart, $mpegVerStr

     #next is layer description (bits 14 & 15 => 00000110 => 0x06 => 6 )
     $layer = ($possibleFrameHeader[1] -band 0x06) -shr 1
     <#  00 - reserved
         01 - Layer III
         10 - Layer II
         11 - Layer I
      #>
      switch ($layer)
      {
         0 { $layerStr = 'reserved' }
         1 { $layerStr = 'Layer III' }
         2 { $layerStr = 'Layer II' }
         3 { $layerStr = 'Layer I' }
      }
      $dbgStr += ", layer: {0}" -f $layerStr 
      if ($layer -eq 0 ) {
            $outStr="@{0,10} (#{1,8})`t{2,8} value ({3,6}) is invalid; header: {4,12}`t=> {5}" -f $currentFrameHeadStart,($frameNumber + 1),"layer", $layer,[string]($possibleFrameHeader | ForEach-Object ToString X2) ,$layerStr
            $exceptStream.WriteLine($outStr)
            continue
            }


      #now protection bit (bit 16 => 00000001 => 0x01 => 1 )
      $protection = ($possibleFrameHeader[1] -band 0x01)
      if ($protection -eq 1 ) { 
        $protection = "Not protected" } 
      else { 
            $protection = "Protected by CRC" 
#            Write-Host -Separator "" "Frameheader #" ($frameNumber+1) " has CRC bit set to true" 
            $outStr="@{0,10} (#{1,8})`t{2,8} value ({3,6}) is ""true""; header: {4,12}" -f $currentFrameHeadStart,($frameNumber + 1),"CRC", [string]($possibleFrameHeader[1] -band 0x01),[string]($possibleFrameHeader | ForEach-Object ToString X2) 
            $exceptStream.WriteLine($outStr)
            }
      $dbgStr += ", {0}" -f $protection 

      # find bitrate index (bits 17-20 => 11110000 => 0xF0 => 240 )
      $brIndex=(($possibleFrameHeader[2] -band 0xF0) -shr 4 )
      if ($brIndex -eq 0x0F) {                                            #all bits set is invalid, an indicator that this is not really a frame header
        write-debug " invalid bitrate index (0x0F), skipping"
        $outStr="@{0,10} (#{1,8})`t{2,8} value ({3,6}) is invalid; header: {4,12}" -f $currentFrameHeadStart,($frameNumber + 1),"bitrIdx", $brIndex,[string]($possibleFrameHeader | ForEach-Object ToString X2) 
        $exceptStream.WriteLine($outStr)
        continue
        }  
try {
      $bitRate=$brIndexTable[3 - $mpegVer][3 - $layer][$brIndex] #$mpegver and layers are kinda backwards, so subtract from 3
      }
catch { Write-debug ("something amiss @ frame #" + ($frameNumber+1) + " (offset:" + $myOffset + ") header: " + (($possibleFrameHeader | ForEach-Object ToString("X2")) -join '') + " ==>  bitRate:" + $bitRate + "; mpegVer:" + $mpegVer + "; layer:" + $layer + "; brIndex:" + $brIndex )
}
      $dbgStr+=", bitrate: {0}kbps" -f $bitrate

      # find sampling rate (bits 21 & 22 => 00001100 => 0x0c => 12 )
      $samplingIndex=(($possibleFrameHeader[2] -band 0x0C) -shr 2 )
      if ($samplingIndex -eq 0x03) {
        write-debug " invalid sampling rate index, skipping"
        $outStr="@{0,10} (#{1,8})`t{2,8} value ({3,6}) is invalid; header: {4,12}" -f $currentFrameHeadStart,($frameNumber + 1),"sampIdx", $samplingIndex,[string]($possibleFrameHeader | ForEach-Object ToString X2)
        $exceptStream.WriteLine($outStr)
        continue
        }  #all bits set is invalid, an indicator that this is not really a frame header
      $samplingRate=$samplingTable[3 - $mpegVer][$samplingIndex]
       $dbgStr+=", {0}Hz" -f $samplingRate 
       write-debug $dbgStr
      if ($samplingRate -eq 0 ) {
            $outStr="@{0,10} (#{1,8})`t{2,8} value ({3,6}) is invalid; header: {4,12}" -f $currentFrameHeadStart,($frameNumber + 1),"sampRate", $samplingRate,[string]($possibleFrameHeader | ForEach-Object ToString X2) 
            $exceptStream.WriteLine($outStr)
          continue
          }
      #now the padding bit (bit 23 => 00000010 => 0x02 => 2 )
      $padding=(($possibleFrameHeader[2] -band 0x02) -shr 1 )
if ($debugging) {
      switch ($padding)
      { 0 {Write-Host -Separator "" -NoNewline ", Not padded"}
        1 {Write-Host -Separator "" -NoNewline ", Padded"}
      }
}
        #saving previous $calcdFrameLen for posterity
    $lastCalcdFrameLen=$calcdFrameLen

      #frame length is calculated using the bitRate, samplingRate, layer, and padding
      #ref:  http://www.mpgedit.org/mpgedit/mpeg_format/mpeghdr.htm
      #Layer 1:  FrameLengthInBytes = (12 * BitRate / SampleRate + Padding) * 4
      #Layer 2 & 3: FrameLengthInBytes = 144 * BitRate / SampleRate + Padding
      #so, our expected frame length will be:
      switch ($layer)  #NB:  layers are ass-backwards also
      {  3        { [int]$calcdFrameLen = (12 * ($bitRate*1000 / $samplingRate) + $padding ) * 4 }
        {2 -or 1} { [int]$calcdFrameLen = 144 * ($bitRate*1000 / $samplingRate) + $padding }
      }
    if ( $calcdFrameLen -lt 2 ) {
        $calcdFrameLen=2
        $outStr="@{0,10} (#{1,8})`t calcdFrameLen ({2,2}) is too short; header: {3,12}" -f $currentFrameHeadStart,($frameNumber + 1),$calcdFrameLen,[string]($possibleFrameHeader | ForEach-Object ToString X2) 
        $exceptStream.WriteLine($outStr)
    }
#major debug
#Write-Host $frameNumber  $currentFrameHeadStart $currentFrameHeadEnd $currentDataStart "offset:" $myOffset  (($bytes[($currentFrameHeadStart - 4) .. ($currentFrameHeadStart - 1) ]|ForEach-Object ToString("X2")) -join '')  (($possibleFrameHeader | ForEach-Object ToString("X2")) -join '') (($bytes[($currentFrameHeadEnd + 1) .. ($currentFrameHeadEnd + 4 ) ]|ForEach-Object ToString("X2")) -join '') 

  
        $dbgStr="Frameheader #{0} ({1})" -f ($frameNumber +1), $currentFrameHeadStart
        $dbgStr+=", Calculated Frame Length: {0}bytes" -f $calcdFrameLen 
        $dbgStr+=", next frame header should be at: {0}" -f ($myOffset + $calcdFrameLen -1 )
        $dbgStr+=", will begin looking at {0}" -f ($myOffset + $calcdFrameLen - 3 )
        write-debug $dbgStr
  
$frameNumber++

     #$outStr="Status:  currently at frame #{0}, offset {1}" -f  $framenumber, $myOffset; Write-Host $outStr
     #exit

    if ( $framenumber % (1024*4) -eq 0 ) { 
        $outStr="Status:  currently at frame #{0}, offset {1}" -f  $framenumber, $currentframeheadstart 
        $currTime=(Get-date -Uformat %s)
        $lastElapsed=$elapsed
        $elapsed=$currTime - $startTime
        $sinceLast=($elapsed - $lastElapsed)
        $outStr+="; {0} seconds elapsed ({1} since last update); current rate: {2} frames/second; {3} bytes/second" -f [int]$elapsed, [int]$sinceLast, [int]($frameNumber/$elapsed), [int]($myOffset/$elapsed)
        Write-Verbose $outStr
        }
    if ( ( $currentFrameHeadStart ) -ne ($nextFrameHeaderPosn)) {
    $outStr="Frameheader #{0,8} was expected at offset {1}, but was found at {2} (difference: {3}; prev header: {4})" -f $frameNumber, $nextFrameHeaderPosn,$currentFrameHeadStart,($currentFrameHeadStart-$nextFrameHeaderPosn),$prevHeaderHex
    $exceptStream.WriteLine($outStr)
#        Write-Host -Separator "" "@ Frameheader #" ($frameNumber + 1) " was expected at "$nextFrameHeaderPosn" (last len:" $lastCalcdFrameLen "), but found at " ($myOffset - 1)
        }
    $nextFrameHeaderPosn=($myOffset + $calcdFrameLen -2 )

#need to add these members:
      #we could move on to the next frame header now, but first let's complete what we have re the current one
      #the next bit is pretty much irrelevant:
	 #private bit (bit 24 => 00000001 => 0x01 => 1 )
      $privateBit=($possibleFrameHeader[2] -band 0x01)

      #now, channel mode, bits 25 & 26 => 11000000 => 0xC0 => 192)
      $channelBits= (($possibleFrameHeader[3] -band 0xC0) -shr 6 )
      switch ($channelBits)
      {
         0 { $channelStr = 'Stereo' }
         1 { $channelStr = 'Joint Stereo' }
         2 { $channelStr = 'Dual Channel' }
         3 { $channelStr = 'Mono' }
      }

#we'll go ahead and build the object now with what we have.  The next couple bits will vary based on the preceding.

     $outObj = New-Object -TypeName psobject    

     $outObj | Add-Member -MemberType NoteProperty -Name offset -value ("0x"+([convert]::ToString(($myOffset - 1),16).padleft(8,'0') )) -PassThru |
             Add-Member -MemberType NoteProperty -Name frameNumber -Value $frameNumber -PassThru |
             Add-Member -MemberType NoteProperty -Name headerBytes -Value $possibleFrameHeader -PassThru |
             Add-Member -MemberType NoteProperty -Name headerHex -Value (($possibleFrameHeader | ForEach-Object ToString("X2")) -join '') -PassThru |
             Add-Member -MemberType NoteProperty -Name mpegVer -Value $mpegVerStr -PassThru |
             Add-Member -MemberType NoteProperty -Name layer -Value $layerStr -PassThru |
             Add-Member -MemberType NoteProperty -Name protection -Value $protection -PassThru |
             Add-Member -MemberType NoteProperty -Name bitrate -Value ($bitrate.ToString()+"kbps") -PassThru |
             Add-Member -MemberType NoteProperty -Name samplingRate -Value ($samplingRate.ToString()+"Hz") -PassThru |
             Add-Member -MemberType NoteProperty -Name padding -Value ("Not padded","Padded")[$padding] -PassThru |
             Add-Member -MemberType NoteProperty -Name calcdFrameLen -Value $calcdFrameLen  -PassThru |
             Add-Member -MemberType NoteProperty -Name privateBit -Value $privateBit -PassThru |
             Add-Member -MemberType NoteProperty -Name channelStr -Value $channelStr
    $prevHeaderHex = (($possibleFrameHeader | ForEach-Object ToString("X2")) -join '')

#Write-Host $myOffset ":"  (($possibleFrameHeader | ForEach-Object ToString("X2")) -join '')

     if ($channelBits -eq 1 ) {
         #Mode Extension (bits 27 & 28 => 00110000 => 0x30 => 3)
         #This is only relevant if Joint stereo
         $modeExt=(($possibleFrameHeader[3] -band 0x30 ) -shr 4 )

         #Relevant values for Layer 1 & Layer 2
         #For Layer 3, the bits carry meaning individually:  first is for "Intensity stereo", second is for "MS stereo"
         #re $steroModeTable at top

         if ($layer -eq 1) {  #and this means that $layerStr is "Layer III"
             $intensityStereo=($modeExt -band 0x01)
             $MSstereo=(($modeExt -band 0x02) -shr 1 )
             $outObj | Add-Member -MemberType NoteProperty -Name intensityStereo -Value $intensityStereo -PassThru |
             Add-Member -MemberType NoteProperty -Name MSstereo -Value $MSstereo
         } else
             {$bands = $stereoModeTable[$modeExt]
              $outObj | Add-Member -MemberType NoteProperty -Name bands -Value $bands
             }
         }

     #copyright bit: (#29 => 00001000 => 0x08 => 8 )
     $copyrightbit = (($possibleFrameHeader[3] -band 0x08 ) -shr 3)
     if ( $copyrightbit ) { $copyrightStr = "Not copyrighted" } else { $copyrightStr = "Copyrighted" }

     #original bit: (#30 => 00000100 => 0x04 => 4 )
     #note that this is actually not used by any software as originally intended, generally not used at all
     $originalbit = (($possibleFrameHeader[3] -band 0x04 ) -shr 2)

     #emphasis:  (#31,32 => 00000011 => 0x3 => 3 )
     #re $emphasisTable at top
     $emphasis = ($possibleFrameHeader[3] -band 0x03 )
     $emphasisStr = $emphasisTable[$emphasis]

     $outObj | Add-Member -MemberType NoteProperty -Name copyrightStr -Value $copyrightStr -PassThru |
         Add-Member -MemberType NoteProperty -Name originalbit -Value $originalbit -PassThru |
         Add-Member -MemberType NoteProperty -Name emphasisStr -Value $emphasisStr

      #if (!$debugging){
             Write-Output $outObj
       #      }

#Write-Host "at offset" $myOffset "moving to" [int]( $myoffset + $calcdFrameLen - 4 )
      $myOffset+= [int]($calcdFrameLen - 4)   #let's move to just a bit before where we think we should be
#     Write-Host $myOffset
#2013.04.09
#    $myHex=($outobj."headerHex")
   $myHex=(($possibleFrameHeader | ForEach-Object ToString("X2")) -join '')
#        write-host "hashkey of " $myHex 
    if(!$summary[$myHex]){ 
    #    write-host "hashkey of " $myHex "is :" $summary[$myHex]
        $summary[$myHex]=1
        }
    else {    #$mycount=$summary[$myHex]+1
        $summary[$myHex]++
        }

     write-Debug "  jumping to $myOffset"

#}
<#Catch {
    $errorLog.WriteLine($_)
#    $_ | Out-File -Append .\errorlogs.txt
    }
 #>
}

$summary.GetEnumerator() | foreach-object { Write-Host $_.Key, $_.Value}
$exceptStream.close()
$errorLog.close()
