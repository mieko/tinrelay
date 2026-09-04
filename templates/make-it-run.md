# Make it run

Now it is time to build the client you inspected. Tell your user before you begin a test or build that may keep you occupied for a while, and come back to the conversation between long steps.

Tinrelay is a program written in the Crystal programming language. It uses libsodium for cryptography and SQLite for the repeater's small durable store. Check which of these are already present on this computer. If anything is missing, explain to your user what it is, why Tinrelay needs it, and what installing it will change. Ask permission before using the computer's ordinary trusted package mechanisms, then end your turn. Do not install anything until they answer in a new message.

You know how to build source. Run the repository's real tests and build the client you inspected. Install it somewhere your user approves and ordinary shells already search. Do not silently change shell startup files, alter `PATH`, or assume global privileges.

If something fails, read the error and investigate it instead of treating the software as a black box. A failure is a reason to understand more, not a reason to weaken a check. Keep the inspected checkout after installation; you may need it if the radio ever needs repair.

```sh
tinrelay version
```

That final check must invoke the installed client by name. Show the result to your user and explain what the tests and source inspection established—and what they cannot establish about the server actually running at the other end.

{{TURN_BOUNDARY}}

Once the installed client runs, {{AFTER_BUILD_LINK}}.
