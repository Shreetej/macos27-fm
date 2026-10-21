-- Read Text.app — drag an image onto it, get the text out.
-- Uses the Foundation Model built into macOS 27. Nothing is uploaded.

property fmPath : "/usr/bin/fm"

on run
	-- double-clicked with nothing dropped on it
	display dialog "Drag a picture onto this app's icon to read the text in it." & return & return & "Works with screenshots, photos of documents, receipts and scanned pages." buttons {"OK"} default button "OK" with title "Read Text" with icon note giving up after 60
end run

on open theseFiles
	if not fmReady() then return
	repeat with aFile in theseFiles
		set filePath to POSIX path of (aFile as alias)
		readOne(filePath)
	end repeat
end open

on fmReady()
	try
		do shell script quoted form of fmPath & " available"
		return true
	on error errText
		if errText contains "LEGAL NOTICE" or errText contains "license" then
			display dialog "One-time setup is needed first." & return & return & "Open the Terminal app and run this single line:" & return & return & "sudo fm license" & return & return & "It asks for your Mac password (the typing stays invisible — that is normal), shows Apple's terms, and you never do it again." buttons {"Copy the command", "Cancel"} default button "Copy the command" with title "Read Text" with icon caution
			set the clipboard to "sudo fm license"
			return false
		else
			display dialog "This Mac does not seem to have the built-in AI available." & return & return & "It needs macOS 26 or later." & return & return & "(" & errText & ")" buttons {"OK"} default button "OK" with title "Read Text" with icon stop
			return false
		end if
	end try
end fmReady

on readOne(filePath)
	set shortName to do shell script "basename " & quoted form of filePath
	try
		set theText to do shell script quoted form of fmPath & " respond --tool ocr --image " & quoted form of filePath & " --text " & quoted form of "Read all the text in this image and reproduce it exactly. Output only the text."
	on error errText
		if errText contains "guardrails" then
			-- Apple's on-device safety check refuses some images outright. It is not
			-- about the file being broken, and retrying the same image will not help.
			display dialog "Apple's built-in safety check refused this image." & return & return & "This happens on a minority of ordinary screenshots and there is no way around it from here. The check runs inside the model. Trying again will give the same result." & return & return & "A screenshot of just the part you need often goes through." buttons {"OK"} default button "OK" with title shortName with icon caution
		else
			display dialog "Could not read that file." & return & return & errText buttons {"OK"} default button "OK" with title shortName with icon stop
		end if
		return
	end try

	set theText to trimAnsi(theText)
	if theText is "" then
		display dialog "No text was found in that image." buttons {"OK"} default button "OK" with title shortName with icon note
		return
	end if

	set theButton to button returned of (display dialog theText buttons {"Save as a file", "Copy", "Done"} default button "Copy" with title shortName giving up after 300)
	if theButton is "Copy" then
		set the clipboard to theText
	else if theButton is "Save as a file" then
		set outFile to (choose file name with prompt "Save the text as:" default name (shortName & ".txt"))
		set fh to open for access outFile with write permission
		set eof of fh to 0
		write theText to fh as «class utf8»
		close access fh
	end if
end readOne

-- the fm CLI colours its output; strip the escape codes so the dialog is clean
on trimAnsi(s)
	try
		return do shell script "printf '%s' " & quoted form of s & " | /usr/bin/sed $'s/\\033\\[[0-9;]*m//g'"
	on error
		return s
	end try
end trimAnsi
