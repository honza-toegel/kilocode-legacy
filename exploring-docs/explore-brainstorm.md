# Customizing Kilo Code plugin through comparative analysis

Source: [Claude shared chat](https://claude.ai/share/045bee9e-601b-4f6b-afa7-3308ef8eb3f3)  
Shared by Honza

---

## You

I would like to ask you about one thing. Uh, we use in, uh, ZKB, which is, uh, Zurich Cantonal Bank, um, coding agent called, uh, called Kilo Code. Uh, this is basically, uh, either IntelliJ or Visual Studio Code plugin, uh, which can be used for assisted coding, and we use it currently, uh, with the model which is instance in Switzerland, which is gpt 5.1, uh, on the Azure. Uh, there is, uh, unfortunately no better model so far from Anthropic, uh, or other providers, uh, which is, um, um, which is provided only purely in Switzerland. Therefore, we are basically restricted to use, uh, this model because of Swiss data government so that the data, uh, doesn't cross, uh, the borders, basically. Therefore, GPT five one, uh, with the plug in called Kilo code. And now, uh, what I notice on this, uh, kilo code version five one, uh, is as well lot of Basically, a lot lot of a lot of disadvantages or a lot of downsides, which I'm currently struggle and many of my colleagues simply give up even using that still keeping coding manually because it's so unuseful in certain areas that it's practically sometimes better to write a code by hand. And one of that area which I which I noticed is on tool kilo code that it practically looks like that the... loop of the agent,, it somehow doesn't, uh, measure if the outcome was reached or that's at least my feeling. Sometimes I have to even write, like, literally four times to edit the file with the proposal, which is in the chat because he... lot of the time, write something in the chat that you can adjust the method like this. You can adjust the method like this. And he suggest... adjustion of multiple files but he don't write it into the code itself. So he doesn't edit the files sometimes rather chat. And sometimes he do, but sometimes he do just on the one file and leave to other files, which was intended to be changed intact. So this is the first thing. It looks like either the agentic loop is missing somehow, uh, fulfillment or it's self satisfied whenever it's just written in the chat and doesn't, uh, produce edited files. And, um, yeah, then there are other things, like, the the code which is produced is sometimes simply... syntactically incorrect. Because whenever we use external dependencies, uh, like, which are internal enterprise libraries, it doesn't know them, obviously, because it's just simply not trained to a gpt 5.1. Uh, it doesn't know anything about our bank. And then, uh, it seems to having issues exploring the dependencies. I, uh, let, um, in Claude Code explore the kilo code plug in, and, uh, it turns out that there is nothing about dependencies at all. It simply read the POM XML file because we are using Spring Boot projects. And this POM XML file is all what he knows. He don't have any, um, any attempt even to try to, whatever, download the jar files which are there or or jar file source at the best. This is this is never happening even if I instruct it. It simply stops somewhere in the middle. And so, um, yeah, these two main concerns that I have, like, uh, one is that, um, the agentic loop seems to never measure, uh, the fulfillness in the sense what was actually edited on the on the code. And the second, um, impossibility to produce, uh, statistic, uh, syntactically correct, um, code using the external dependencies, which are normally in the project bounded via the POM XML. Uh, these two are my main concerns. And I would like to, uh, basically, uh, since we are restricted to this plug in, I would like to know, uh, because, uh, if there are some possibilities to, uh, to improve it, and I would like to do it in the way of exploration. So I will Uh, check out this kilo code, plug in code in my private, uh, workstation locally, and I would maybe compare it with, um, some some heist, like, cutting edge, uh, open source, uh, coding agent and try to compare some metrics. Uh, for example, I guess, the... one of the most important seems to be, like, there are some predefined modes of the agent, like architect, uh, coder, um, ask mode, and those modes, uh, in the end of the day, they produce some prompt, which is, uh, of course, obviously, customizable, and that I can customize in our enterprise environment. So I assume comparing that, uh, piece of code would... may help me to, uh, set it better, uh, in favor of better results. And maybe it allows me as well to understand why is it not, um, why is it not, uh, exploring the dependencies as I would like. And, uh, yeah, the, um, maybe you can have a suggestion how to how to approach such concerns while still keeping in the mind the restriction that, um, yeah, uh, let's use still the existing, uh, plug in, kilo code, and, uh, let's focus on what customization could be made and, uh, possibility that I can, uh, simply literally check check out the source code of that plug in because it's open source and compare with the other plug in using a a Claude Code to get the best results, what could be the customization. That's my idea. But maybe you have you have better ideas how to approach such a such a tweaking exercise of existing agent plugin.

---

## Claude

Good context to work with — the Cline → Roo Code → Kilo Code lineage is well documented, all Apache-2.0, so a side-by-side code comparison is a genuinely sound research method (not just theoretically possible — Kilo literally still merges upstream from both). One thing worth checking first: Kilo Code did a fairly major rebuild in April 2026 on top of "OpenCode" with parallel tool calls and subagents — confirm which Kilo version ZKB has deployed, since the internals you'd be diffing may have changed significantly from the classic Cline-style architecture.

**On symptom 1 (proposes edits in chat, doesn't apply them)**

This is very likely a tool-call reliability problem, not a "measuring success" problem. The classic Cline/Roo/Kilo lineage historically parsed tool calls via custom XML-style tags embedded in the model's text output, rather than relying purely on the provider's native function-calling. GPT-5.1 may not reliably emit that exact format every turn — when parsing fails, the harness's fallback is often just to render the raw text as a chat message instead of retrying. Things worth inspecting in the source and in your settings:

- Which diff-apply strategy is configured — whole-file rewrite vs search/replace-style diff. Diff-based edits require stricter formatting and are more failure-prone with models that aren't tuned to that exact syntax.
- Whether there's a "max consecutive mistakes" or similar limit that silently degrades to chat-only output after N failed tool calls — this matches your "sometimes edits one file and abandons the rest" pattern exactly.
- Whether native OpenAI function-calling is used for GPT-5.1 vs the legacy XML parser (check the provider-handler code path for OpenAI/Azure).

Cheap mitigation you can try today without touching code: add explicit custom instructions (Kilo supports `.kilocodemodes`/rules files) stating something like "never describe a change only in chat text; every proposed change must be applied via the file-edit tool before the turn ends; at the end, list every file actually modified." This won't fix a parsing bug but often meaningfully reduces the failure rate.

**On symptom 2 (no real dependency exploration)**

Your finding is consistent with the architecture: these tools default to grep/tree-sitter-based symbol lookup (`list_code_definition_names`) plus an optional local embeddings index over files already in the workspace. None of the Cline-lineage tools fetch jar sources or resolve Maven coordinates — that's out of scope by design, and it's a sandboxing issue on top (no internet access to Maven Central even if it tried). Two practical angles:

1. Pre-extract sources jars for your key internal libraries (via your internal Nexus/Artifactory) into a reference folder inside the workspace, and add a custom instruction telling the agent to consult that folder for unknown internal symbols before guessing.
2. Check whether Kilo's codebase-indexing feature is enabled and pointed at that folder too — if it's only indexing `src/`, it'll never surface those symbols even when they're present on disk.

**On your comparative research plan**

Good instinct, and doable in an afternoon or two:

- Compare mode/system-prompt definitions across Kilo, Roo Code (archived but still readable, v3.54.0), and Cline — since Kilo forked both, diffing the prompt files directly (usually under something like `src/core/prompts` or a `modes` config) will show you exactly what's inherited vs Kilo-specific, and where the tool-call format is defined.
- Also worth a look: Aider is known for a more robust repo-map (ctags/tree-sitter-based) approach to codebase understanding and has a cleaner, well-documented diff-apply mechanism — useful as a reference implementation even though it's a different lineage entirely, and might explain patterns worth borrowing into your custom instructions.
- Concrete metric to track: for a fixed set of test prompts, log (a) % of proposed changes actually written to disk vs left as chat text, and (b) whether unknown internal symbols get looked up correctly with vs without the extracted-sources folder present.

Since this is all analysis of the plugin's own open-source code on your private machine, not bank data, you're on solid ground there. Happy to help you draft the custom instruction rules file or dig into a specific part of the Kilo source if you paste it in.

---

## You

what is in the world of open source agents, uh, like the best, uh, leading, uh, cutting edge, uh, coding agent currently? Is it, um, something like, uh, OpenCode or Codex? Or... I'm not sure if Anthropic has something open source. Probably not.

---

## Claude

Short answer: no, Anthropic doesn't open-source Claude Code — your suspicion was right, it's proprietary. Your instinct about OpenCode is on the money though.

**Current state (mid-2026):**

- **OpenCode** — the clear leader by adoption. MIT-licensed, ~170-180k GitHub stars (more than Claude Code or Codex CLI have), terminal-native, provider-agnostic (75+ providers, works with any API key or local models via Ollama). It's the closest thing to an open "Claude Code equivalent." Worth noting for you specifically: Kilo Code's April 2026 rebuild actually runs on top of OpenCode's harness now, so studying OpenCode's internals may double as understanding Kilo's current architecture.
- **Codex CLI** — also genuinely open source (Apache-2.0), and currently tops the Terminal-Bench 2.1 leaderboard when paired with GPT-5.5. But that benchmark lead comes from the closed model behind it, not the harness itself — the harness is well-engineered (strong sandboxing) but tightly built around OpenAI's function-calling conventions.
- **Aider** — smaller, older, very mature. Its git-native, diff-and-auto-commit workflow and repo-map (tree-sitter/ctags-based) approach to codebase understanding is still one of the most robust references for the exact dependency-exploration problem you're hitting.
- **Cline** — the original of the Cline→Roo→Kilo lineage, still actively maintained, Apache-2.0, praised for stricter human-in-the-loop approval (better audit trail, which might matter for a bank).

One thing that's actually relevant to your constraints: since you're stuck on self-hosted/data-residency requirements anyway, the open-weight model **Kimi K3** paired with OpenCode is getting attention specifically as a self-hostable stack for regulated environments — closes a lot of the gap with frontier closed models while keeping everything on your own infrastructure. Might be worth a look for future options, even if it's not solving your immediate GPT-5.1-on-Azure-Switzerland setup.

For your comparison exercise: OpenCode + Aider are probably the two most useful reference implementations — OpenCode for the current-gen harness architecture (and its overlap with Kilo Code post-rebuild), Aider for the dependency/repo-map handling you're missing.
