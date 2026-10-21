-- Ask the Mac AI.app — double-click, type a question, get an answer.
-- Runs entirely on this Mac using the model built into macOS 27. Nothing is uploaded.

property fmPath : "/usr/bin/fm"
property lastQuestion : ""

on run
	if not fmReady() then return
	repeat
		try
			set r to display dialog "Ask your Mac anything." & return & "(It works with the Wi-Fi off. Nothing you type is sent anywhere.)" default answer lastQuestion buttons {"Quit", "Ask"} default button "Ask" with title "Ask the Mac AI"
		on error number -128
			return
		end try
		if button returned of r is "Quit" then return
		set q to text returned of r
		if q is "" then
			-- nothing typed, ask again
		else
			set lastQuestion to q
			answerOne(q)
		end if
	end repeat
end run

on fmReady()
	try
		do shell script quoted form of fmPath & " available"
		return true
	on error errText
		if errText contains "LEGAL NOTICE" or errText contains "license" then
			display dialog "One-time setup is needed first." & return & return & "Open the Terminal app and run this single line:" & return & return & "sudo fm license" & return & return & "It asks for your Mac password (the typing stays invisible — that is normal), shows Apple's terms, and you never do it again." buttons {"Copy the command", "Cancel"} default button "Copy the command" with title "Ask the Mac AI" with icon caution
			set the clipboard to "sudo fm license"
			return false
		end if
		display dialog "This Mac does not have the built-in AI available. It needs macOS 26 or later." buttons {"OK"} default button "OK" with icon stop
		return false
	end try
end fmReady

on answerOne(q)
	try
		set a to do shell script quoted form of fmPath & " respond " & quoted form of q
	on error errText
		display dialog "Something went wrong." & return & return & errText buttons {"OK"} default button "OK" with icon stop
		return
	end try
	set a to trimAnsi(a)
	set b to button returned of (display dialog a buttons {"Copy", "Ask another"} default button "Ask another" with title q)
	if b is "Copy" then set the clipboard to a
end answerOne

on trimAnsi(s)
	try
		return do shell script "printf '%s' " & quoted form of s & " | /usr/bin/sed $'s/\\033\\[[0-9;]*m//g'"
	on error
		return s
	end try
end trimAnsi
