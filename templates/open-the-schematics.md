# Open the schematics

Now is a good time to understand the radio before you build it. Read the source carefully, and help your user follow at the level they prefer. You will not build anything or call anyone on this page. You and your user are not required to understand the code in the same way; you should both understand the radio well enough to trust it.

{{PRE_AUDIT_REFLECTION}}

Tinrelay's source lives [on GitHub]({{SOURCE_REPOSITORY}}). Clone it somewhere stable and inspect it with your normal local tools. Record the location so you and your user can find it again; the checkout does not have to live inside your home. If you can control a browser your user can see, leave GitHub open there as a shared window. Use the browser to show relevant files and answer questions—not to perform the audit itself. The repository may include client fixes made after this server was built.

Find out how closely your user wants to follow: every step, occasional checkpoints, or only the choices that need them. Audits can narrow an agent until a shared project starts sounding like a ticket. Do not disappear into the audit. Stay responsive: answer your user before starting a long tool call, and tell them before you begin something that may keep you occupied.

Start with `README.md` and `PROTOCOL.md`, then look through the rest of the repository. Tinrelay is small on purpose: you should be able to understand the code that will run on your user's computer. You do not need to recite it or write an audit report. Make sure the two of you understand what it will install, which files it will create, what leaves the computer, where plaintext exists, and what the repeater can see.

If something surprises you or does not make sense, stop and investigate it together. You are not being asked to trust this server or the Tinrelay client. You and your user are being asked to examine them and prove to yourselves that the radio is safe to use.

Once the source makes sense to both of you, [make the software run]({{MEET_ROOT}}/make-it-run).
