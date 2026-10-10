import 'guide_model.dart';

const guideGroups = [
  'START HERE',
  'WORKING',
  'CHECKING AND SHIPPING',
  'AROUND THE WORK',
];

/// The guide, written the way you'd explain haro to a friend sitting next to you: everyday words
/// first, the exact names of buttons second. Keep it true to what the app does today
/// (`CHANGELOG.md` is the record), and when a feature changes, change its topic here.
const List<GuideTopic> guideTopics = [
  GuideTopic(
    id: 'welcome',
    title: 'What haro is',
    group: 'START HERE',
    summary:
        "haro is a desktop app for getting code written on your own computer, with an AI helper "
        "or without one, while you stay the one in charge.",
    blocks: [
      GuideParagraph(
        "Every task you start gets its own **workspace**: a separate copy of your project's "
        "files. You can try things there without risking anything else. When you're happy with "
        "the result, the tests have to pass, and only then can it be merged back.",
      ),
      GuideParagraph(
        "You decide who writes the code. In **Manual** mode, you write every line yourself. In "
        "**Agent** mode, an AI coding agent writes it, and you can fence it in so it only "
        "touches the files you name. Either way, haro keeps a **receipt** that says who wrote "
        "what.",
      ),
      GuideTip(
        "haro doesn't have a server of its own. It runs on your computer and uses your own git. "
        "The agent talks to Claude with your own login (or to a model on your own machine), and "
        "GitHub comes in when you open or check a pull request.",
        label: 'WORTH KNOWING',
      ),
      GuideHeading('Every task goes the same way'),
      GuideSteps([
        "**Agent:** tell the agent what you want (you skip this one in Manual mode).",
        "**Code:** read and change the files in the built-in editor.",
        "**Review:** look at what changed and run the tests.",
        "**Ship:** merge it, or open a pull request.",
      ]),
      GuideHeading('Where do you want to start?'),
      GuidePaths([
        GuidePath(
          'I write code and I want to stay in control',
          "Start in Manual mode. You write it, haro runs the tests and keeps the receipt.",
          'who-writes',
        ),
        GuidePath(
          'I want an AI to write it, and I want to check it',
          "Use Agent mode. You fence off what it can touch, then review what it did.",
          'agent',
        ),
        GuidePath(
          "I'm new to code or git",
          "Start with the plain-words list, then follow one small task from start to finish.",
          'words',
        ),
      ]),
      GuideSeeAlso(['first-task', 'words']),
    ],
  ),
  GuideTopic(
    id: 'words',
    title: 'Plain words',
    group: 'START HERE',
    summary:
        "The few terms haro uses, in everyday language. Skim it once, and come back whenever "
        "a word is new.",
    blocks: [
      GuideTerms([
        (
          'Project',
          "One of your git repositories, which is the folder your code lives in. You add it to "
              "haro once.",
        ),
        (
          'Workspace',
          "One task inside a project. It has its own copy of the files and its own branch, so "
              "tasks never get in each other's way.",
        ),
        (
          'Branch',
          "A named line of changes. Your work happens on its own branch, and your main branch "
              "stays untouched until you merge.",
        ),
        (
          'Worktree',
          "The extra copy of your project's files that a workspace uses. It's a real folder on "
              "your disk, so you can open it in any editor.",
        ),
        (
          'Diff',
          "The list of what changed: lines that were added, and lines that were removed.",
        ),
        (
          'Commit',
          "A saved snapshot of your changes, with a short message. Work has to be committed "
              "before it can be shipped.",
        ),
        (
          'Merge',
          "Folding your branch back into the main one, so your change becomes part of the "
              "project.",
        ),
        (
          'Pull request (PR)',
          "A request, on GitHub, for your change to be merged. It's useful when other people "
              "want to look at it first.",
        ),
        (
          'Tests and the gate',
          "Before you can ship, haro runs your project's tests. That check is called the gate. "
              "Green means the tests passed. Red means something failed.",
        ),
        (
          'Agent',
          "The AI that writes code for you in Agent mode. It's Claude Code, running on your own "
              "Claude login, or a model on your own machine.",
        ),
        ('Prompt', "What you type to tell the agent what to do."),
        (
          'Fence (the Scope box)',
          "A list of the files and folders the agent is allowed to change in one run. If it "
              "changes anything else, haro puts it back.",
        ),
        (
          'Receipt',
          "A short summary of a piece of work: the tests, who wrote it, and which files the "
              "agent was fenced to. You can copy it into a pull request.",
        ),
        (
          'Dev server',
          "The app you're building, running so you can look at it in your browser. haro can "
              "start and stop it for you.",
        ),
      ]),
      GuideSeeAlso(['first-task', 'welcome']),
    ],
  ),
  GuideTopic(
    id: 'first-task',
    title: 'Your first task',
    group: 'START HERE',
    summary:
        "A walk from an empty app to a merged change, one step at a time. It takes about ten "
        "minutes.",
    blocks: [
      GuideSteps([
        "**Add a project.** Press **Add project** at the bottom of the sidebar. Pick a folder "
            "on your computer that's already a git repository (use Browse…), or clone one from "
            "a link.",
        "**Let haro check your tests.** The first time, haro looks for your project's test "
            "command and runs the tests once on your main branch, so you know whether it was "
            "healthy before anyone touched it. If haro found the right command, accept it. If "
            "not, pick a different one.",
        "**Start a workspace.** Press {mod}+N, describe the task in a few words, and choose "
            "**Who writes it**: Agent or Manual. In Agent mode, haro can start the agent right "
            "away.",
        "**Do the work.** In Agent mode, type what you want in the box at the bottom, send it, "
            "and watch the agent work. In Manual mode, you land in the editor and write it "
            "yourself.",
        "**Review it.** Open the Review step, run the tests, read the overview at the top, look "
            "through each changed file, and tick **Viewed** as you go.",
        "**Ship it.** On the Ship step, read the receipt, then merge (haro asks twice, on "
            "purpose) or open a pull request.",
      ]),
      GuideTip(
        "You can only click the step you're on. The others are dimmed. Use **Proceed** and "
        "**Back** at the bottom to move between them.",
      ),
      GuideHeading("If something goes wrong"),
      GuideBullets([
        "Tests are red? Read \"The test gate\".",
        "The agent did something you didn't want? Read \"When things go wrong\".",
        "A word you don't know? Read \"Plain words\".",
      ]),
      GuideSeeAlso(['who-writes', 'review', 'ship']),
    ],
  ),
  GuideTopic(
    id: 'projects',
    title: 'Projects and workspaces',
    group: 'WORKING',
    summary: "How your work is organized, and how to find what needs you.",
    blocks: [
      GuideParagraph(
        "The sidebar lists your projects, with each project's workspaces under it. Click a "
        "workspace to open it. Right-click a project or a workspace to see more things you can "
        "do, like renaming, deleting or opening it in your editor.",
      ),
      GuideHeading('The dashboard'),
      GuideParagraph(
        "The home screen sorts every workspace so the ones that need you are at the top.",
      ),
      GuideTerms([
        (
          'Needs you',
          "Something is waiting for you: a red gate, a plan to approve, or items to look at.",
        ),
        ('Running', "An agent or the tests are working right now."),
        ('Ready to ship', "Green, and nothing left to look at."),
        ('Idle', "Waiting for a task."),
        ('Merged', "Shipped. These are folded away by default."),
      ]),
      GuideParagraph(
        "Under the big headline you might see something like \"3 workspaces waiting for your "
        "review\". That's agent work you haven't reviewed yet. Hover over it to see what it "
        "counts and how to change the limit.",
      ),
      GuideTip("Press {mod}+J to jump to the next workspace that needs you."),
      GuideHeading('Starting and finishing a workspace'),
      GuideBullets([
        "**New workspace** ({mod}+N) asks for a name for the task, the branch to start from, "
            "and who writes it.",
        "**After a merge,** the workspace stays so you can look back at it. Use **Continue on a "
            "new branch** for a follow-up, or **Delete workspace** to clean up. Deleting stops "
            "anything that's running and removes its folder.",
        "**Remove project** (right-click it in the sidebar) shows you what it's about to take "
            "down, and asks you to type the name if anything hasn't been merged.",
      ]),
      GuideSeeAlso(['who-writes', 'safety']),
    ],
  ),
  GuideTopic(
    id: 'who-writes',
    title: 'Manual or agent: who writes it',
    group: 'WORKING',
    summary:
        "Every workspace is one or the other, and you can switch. This choice decides who "
        "types the code.",
    blocks: [
      GuideTerms([
        (
          'Manual',
          "You write every line. The agent is switched off for this workspace, and nothing in "
              "haro can start one. A small helper on the side can plan and look things up, but "
              "it can't change your files.",
        ),
        (
          'Agent',
          "An AI coding agent writes the code from your prompt. You decide how much it may "
              "touch, and you review the result.",
        ),
      ]),
      GuideParagraph(
        "To switch, use the **AGENT | MANUAL** control at the top of the window, or the command "
        "palette. Going from Manual to Agent asks you first. If you have unsaved work, haro "
        "saves it as a checkpoint commit, so what you wrote and what the agent wrote stay "
        "separate.",
      ),
      GuideTip(
        "The receipt says which one it was: \"you, by hand\", \"agent\", or a mix, with the "
        "times you switched. It's a record of what happened inside haro. It can't see what you "
        "did in other tools.",
        label: 'WHY IT MATTERS',
      ),
      GuideSeeAlso(['manual-rail', 'agent', 'code-step']),
    ],
  ),
  GuideTopic(
    id: 'agent',
    title: 'Working with the agent',
    group: 'WORKING',
    summary:
        "How to ask for what you want, what the options under the box do, and how to keep an "
        "eye on a run.",
    blocks: [
      GuideParagraph(
        "In Agent mode, the first step is a conversation. Type what you want in the box at the "
        "bottom and press {mod}+Enter. The agent remembers what you've talked about, so "
        "follow-ups can be short, like \"also handle the empty case\".",
      ),
      GuideHeading('The options under the box'),
      GuideTerms([
        (
          'Plan first',
          "The agent writes up a plan and changes nothing. You read it, then approve it to "
              "start building.",
        ),
        (
          'Test first',
          "The agent writes only a failing test for the behavior you want. You approve the "
              "test, then it builds the code. The test is locked, so nobody can quietly change "
              "it to make things pass.",
        ),
        (
          'Model and effort',
          "Which Claude model to use, and how hard it should think. Bigger and harder costs "
              "more.",
        ),
        (
          'Scope',
          "The files the agent may change. See \"Keeping the agent inside the lines\".",
        ),
      ]),
      GuideHeading('Good to know'),
      GuideBullets([
        "If you paste something very long, like a stack trace, it turns into a small chip and "
            "goes along as a file, so it doesn't flood your prompt.",
        "A run waits if setup is still running, or if too many agents are already working. It "
            "starts by itself as soon as there's room.",
        "Closing haro while an agent is working asks you first. If you quit anyway, the agent "
            "stops, and your files stay in their workspace. Press **Stop** to end a run "
            "yourself.",
        "The side panel shows the model, the cost so far, how long the run has gone and how "
            "much of its memory is used. If the agent hands work to helpers, you'll see them "
            "under AGENTS, and you can open or stop each one.",
        "When the agent finishes, the tests don't start on their own. You start them from the "
            "Review step. (A project can choose to run them automatically.)",
      ]),
      GuideSeeAlso(['fence', 'review', 'safety']),
    ],
  ),
  GuideTopic(
    id: 'fence',
    title: 'Keeping the agent inside the lines',
    group: 'WORKING',
    summary: "The Scope box under the prompt lists the only files the agent can change in a run.",
    blocks: [
      GuideParagraph(
        "Leave it empty and the agent can change any file. Add a few and it can only change "
        "those. It can always read everything.",
      ),
      GuideSteps([
        "Click the **Scope** box. A list of your folders and files opens.",
        "Click a folder (everything inside it is allowed) or a single file. You can also "
            "start typing a name: \"comp\" finds \"app/components/\".",
        "Each choice becomes a chip. To take one out, click the ✕ on it, or press Backspace in "
            "the empty box.",
        "Send your prompt as usual.",
      ]),
      GuideBullets([
        "If the agent tries to change something outside the list, haro usually stops it before "
            "it's written, and tells the agent why.",
        "Whatever still ends up outside (a shell command can do that) is put back when the run "
            "ends. What the agent wrote there is kept aside, so nothing is lost.",
        "If the agent needs another file, it's told to say so and stop. Add the file to the "
            "Scope and send again.",
        "Your own uncommitted work from before the run is kept. The one catch: if you edit a "
            "file outside the fence while the run is going, that edit is put back too (a copy "
            "is kept).",
        "A plan run changes nothing, and the test-first draft only writes one new test file, "
            "so neither uses the fence.",
      ]),
      GuideTip(
        "The fence is about files. It can't stop the agent from running commands or using the "
        "network, and the Review step reminds you of that every time.",
        label: 'HEADS UP',
      ),
      GuideSeeAlso(['agent', 'safety', 'review']),
    ],
  ),
  GuideTopic(
    id: 'code-step',
    title: 'The Code step',
    group: 'WORKING',
    summary:
        "A small editor for reading and changing the files in your workspace.",
    blocks: [
      GuideParagraph(
        "On the left you get a file tree (it follows your disk and respects .gitignore), "
        "search, a list of your changes, and the Gate view. In the middle there's a tabbed "
        "editor. Edits you haven't saved survive switching tabs, and your open tabs come back "
        "after a restart.",
      ),
      GuideBullets([
        "**Jump to a file** with {mod}+P. Add \":42\" to land on a line.",
        "**Search across all files** with {mod}+Shift+F.",
        "**Save** with {mod}+S. If you turned on \"run on save\", saving also runs the tests.",
        "**Changes** lists what you've changed and lets you stage files one at a time before "
            "a commit.",
        "**Saving is safe.** If the file changed on disk while you had it open, haro asks "
            "whether to overwrite it, reload it, or cancel.",
        "**Open in…** ({mod}+Shift+O) opens the workspace folder in your own editor.",
        "**Focus mode** ({mod}+Shift+Enter) hides the extras so you can concentrate. Press "
            "Esc to bring them back.",
      ]),
      GuideTip(
        "The small marks in the editor's left margin show what changed, which lines a passing "
        "test ran, and places that deserve a second look. They're hints, never a verdict.",
      ),
      GuideSeeAlso(['gate', 'review']),
    ],
  ),
  GuideTopic(
    id: 'manual-rail',
    title: 'The helper in Manual mode',
    group: 'WORKING',
    summary:
        "In Manual mode there's a read-only assistant in the side panel, with three tabs: "
        "Plan, Search and Docs.",
    blocks: [
      GuideParagraph(
        "It can read and think, but it can't change a single file. haro checks that too: it "
        "looks at your workspace before and after every answer, so \"AI edits: 0\" is "
        "something that was measured, not just promised.",
      ),
      GuideTerms([
        (
          'Plan',
          "Describe a task and get a short checklist of steps and files. Tick steps off as you "
              "go. The plan is added to your pull request.",
        ),
        (
          'Search',
          "Ask \"where should I look for…\". You get a short answer and pointers to real "
              "files, plus quick looks through your git history. It points the way, it doesn't "
              "paste code.",
        ),
        (
          'Docs',
          "Your saved plans, links you've pinned, and manual pages that are on your machine.",
        ),
      ]),
      GuideSeeAlso(['who-writes', 'code-step']),
    ],
  ),
  GuideTopic(
    id: 'review',
    title: 'Reviewing the work',
    group: 'CHECKING AND SHIPPING',
    summary:
        "The Review step is where you decide whether the change is fine. It starts with an "
        "overview, then goes through the files one by one.",
    blocks: [
      GuideHeading('The overview'),
      GuideTerms([
        (
          'Intent',
          "What was asked, taken from the first prompt, plus how many follow-ups came after.",
        ),
        (
          'Fence',
          "How far the agent was allowed to go, and anything that was refused or put back. It "
              "says \"Not fenced\" when it could change any file.",
        ),
        (
          'Size',
          "How many lines changed, and a bar that shows it against 100 and 400 lines. Hover "
              "over the bar for a plain explanation. Big changes take longer to read well, so "
              "the page suggests fencing the next run to fewer files.",
        ),
      ]),
      GuideHeading('Files changed'),
      GuideParagraph(
        "Every changed file has its own diff you can open. They're in a sensible order: first "
        "the files with lines no test ran, then the riskier kinds (CI, dependencies, settings, "
        "database, sign-in) and tests that got weaker, then new tests, then everything else, "
        "and generated files last. A small label tells you which kind each one is.",
      ),
      GuideSteps([
        "Open a file and read its diff.",
        "Tick **Viewed** and it folds away. If the file changes again later, you'll need to "
            "view it again.",
        "Once every file is viewed and the tests are green, **Proceed to ship** unlocks.",
      ]),
      GuideHeading('Needs your review'),
      GuideParagraph(
        "This is a list of things haro noticed but can't judge for you: a changed file that no "
        "test touches, lines no test ran, a new dependency, a possible secret, a deleted file, "
        "or a test that got weaker. Tick each one once you've looked at it. You can also open "
        "it in the editor, send it to the agent, or add it to the backlog.",
      ),
      GuideHeading('Review with AI'),
      GuideParagraph(
        "There's an optional button above the files. It asks an AI to read the diff and point "
        "things out. It's only advice: it never decides whether the tests pass, and it never "
        "blocks you from shipping.",
      ),
      GuideTip(
        "haro keeps count of how many files you marked Viewed and roughly how long each one "
        "was open, and puts that on the receipt as a plain fact. It never says you \"reviewed\" "
        "something, because it can't know what you understood.",
        label: 'ON THE RECEIPT',
      ),
      GuideSeeAlso(['gate', 'ship']),
    ],
  ),
  GuideTopic(
    id: 'gate',
    title: 'The test gate',
    group: 'CHECKING AND SHIPPING',
    summary:
        "haro runs your tests before you can ship. Here's how to read the result, and what to "
        "do when it's red.",
    blocks: [
      GuideParagraph(
        "The gate is just your project's own tests, run by haro. Start it from the Review step "
        "({mod}+G). The result comes from actually running the tests, never from an AI's "
        "opinion.",
      ),
      GuideTerms([
        ('Green', "The tests passed. You can ship."),
        (
          'Green with a star',
          "The tests passed, but the test suite itself got weaker than before (a test was "
              "removed or skipped, or a check was loosened). Take a look before you ship.",
        ),
        (
          'Red',
          "Something failed, or a safety check blocked the result. The page tells you which.",
        ),
        (
          'Setup',
          "The tests couldn't even start, for example because installing the dependencies "
              "failed. A red banner shows the last lines of output and a **Re-run setup** "
              "button.",
        ),
      ]),
      GuideHeading("When it's red"),
      GuideSteps([
        "Read the failing tests and what they expected.",
        "Fix the code, or press **Send failures to agent** in Agent mode.",
        "Run the gate again ({mod}+G).",
        "If every test passed and it's still red, a safety check blocked it: a drop in "
            "coverage, a merge that wouldn't apply cleanly, or a weaker test. The page names "
            "it.",
      ]),
      GuideHeading('Extra evidence'),
      GuideBullets([
        "**Per-line proof:** on a green run, every added line is marked as either run by a "
            "test or never run. It means a test ran the line. It doesn't mean anything checked "
            "the result.",
        "**Secrets scan:** if gitleaks is installed, haro checks your changes for things that "
            "look like keys or passwords. It's advice, and it never decides green or red.",
        "**Tamper alarm:** that's the green with a star above.",
      ]),
      GuideSeeAlso(['review', 'ship', 'settings']),
    ],
  ),
  GuideTopic(
    id: 'ship',
    title: 'Shipping',
    group: 'CHECKING AND SHIPPING',
    summary: "The receipt, committing, merging, and opening a pull request.",
    blocks: [
      GuideParagraph(
        "haro won't merge unless the gate is green. If your project has no remote, it merges "
        "into your base branch on your own computer, and stops cleanly if there's a conflict. "
        "If there is a remote, it uses your own GitHub login to open or merge a pull request.",
      ),
      GuideSteps([
        "If you have uncommitted changes, write a message and press **Commit**. haro never "
            "ships uncommitted work by surprise.",
        "Read the **receipt**: the tests, who wrote it, the fence, and what was refused or "
            "checked.",
        "If you like, type one sentence under the receipt about why you're approving this. "
            "Only you write it. haro never fills it in for you.",
        "Press **Merge into main**, then **Confirm merge**. Or press **Open pull request**.",
      ]),
      GuideTerms([
        (
          'Copy markdown / Copy for PR',
          "Copy the receipt, or a short block (what was asked, what the agent was limited to, "
              "the evidence, your reason) to paste into a pull request.",
        ),
        (
          'Post to PR',
          "Adds the receipt to an open pull request as a comment.",
        ),
        (
          'Continue on a new branch',
          "After a merge, starts the next piece of work in the same workspace.",
        ),
      ]),
      GuideTip(
        "If a pull request gets merged on github.com, the workspace flips to Merged by itself "
        "within about half a minute.",
      ),
      GuideSeeAlso(['gate', 'safety']),
    ],
  ),
  GuideTopic(
    id: 'safety',
    title: 'When things go wrong',
    group: 'CHECKING AND SHIPPING',
    summary: "How to undo an agent run, what haro won't let the agent do, and how to stop it.",
    blocks: [
      GuideHeading('Put your files back to before a run'),
      GuideParagraph(
        "Every agent run keeps a copy of your workspace as it was when the run started. Under "
        "the newest run in the agent stream, press **Restore files to before this run**. haro "
        "asks first, puts your files back, and keeps what was there a moment ago, so you can "
        "undo the undo.",
      ),
      GuideBullets([
        "It restores files, not history. If the agent made a commit, the commit stays.",
        "It won't run while the agent or the tests are working.",
        "Files your project ignores, like node_modules, aren't saved or touched.",
      ]),
      GuideHeading("Things haro won't let through"),
      GuideParagraph(
        "Whatever the agent tries to run in a shell goes past a short block-list first. If it "
        "matches, haro refuses it, tells the agent why, and lists it on the receipt. The list "
        "covers things like `git reset --hard`, `git clean -f`, `git push --force`, deleting "
        "the whole workspace or a folder outside it, and reading `.env` files or private keys.",
      ),
      GuideTip(
        "This is a quick check on the text of a command. It's not a guarantee. A command that "
        "gets through wasn't looked at closely, which is why the restore above exists.",
        label: 'HEADS UP',
      ),
      GuideHeading('Stopping and starting over'),
      GuideBullets([
        "**Stop** ends a run and everything it started.",
        "Anything outside your Scope gets put back after a run.",
        "You can always delete the workspace and start over. Nothing touches your main branch "
            "until you merge.",
      ]),
      GuideSeeAlso(['fence', 'agent']),
    ],
  ),
  GuideTopic(
    id: 'backlog',
    title: 'Backlog and Notes',
    group: 'AROUND THE WORK',
    summary: "A place for what you want to do next, and a place to think before it becomes a task.",
    blocks: [
      GuideParagraph(
        "Open the **Backlog** from the sidebar or the palette. It reads checklist lines (like "
        "\"- [ ] do this\") from the markdown files in your project's backlog folder, and it "
        "shows your GitHub issues using your own login.",
      ),
      GuideBullets([
        "The line at the top adds a todo. The box checks it off. The ··· menu edits it, moves "
            "it, or deletes it.",
        "**Start as workspace** opens a new workspace with the todo already filled in.",
        "**Capture a todo from anywhere** with {mod}+Shift+T. Type one line, press Enter, and "
            "it lands in your inbox.",
        "If an agent changed the file while you were looking at it, haro tells you and "
            "reloads, instead of editing the wrong line.",
      ]),
      GuideHeading('Notes'),
      GuideParagraph(
        "The **Notes** tab holds free-form pages, saved as plain markdown files inside your "
        "project, so they travel with git and open in any editor. They save by themselves, and "
        "haro won't overwrite a note that changed on disk without asking you. Select some text "
        "and press **Make todo**, or **Start as workspace**, to turn a thought into work.",
      ),
      GuideTip("Only you write notes. No agent action edits them."),
      GuideSeeAlso(['projects']),
    ],
  ),
  GuideTopic(
    id: 'run-app',
    title: 'Running your app',
    group: 'AROUND THE WORK',
    summary: "Start the thing you're building and look at it in your browser.",
    blocks: [
      GuideParagraph(
        "If your project has a run command, the side panel has an **APP** section: the "
        "address, a RUNNING or STOPPED badge, and buttons to run or stop the app, open it in "
        "your browser, and show its log. ({mod}+R runs it.)",
      ),
      GuideBullets([
        "Each workspace gets its own port, so several workspaces can run side by side.",
        "The app's output shows up in the **Dev log** tab of the bottom panel. The terminal "
            "toggle is Ctrl+` on every system.",
        "The agent can start, stop and read the log of your app by itself, so \"restart it "
            "and tell me what it returns\" works without extra instructions.",
        "If your app listens on fixed ports of its own, give its run command a `url` in "
            "settings, so Open goes to the right place.",
      ]),
      GuideTip(
        "The side panel only shows the default run for now. A project with several (a "
        "frontend and a backend, say) still starts fine, and the agent can drive each one by "
        "name.",
        label: 'HEADS UP',
      ),
      GuideSeeAlso(['settings']),
    ],
  ),
  GuideTopic(
    id: 'settings',
    title: 'Settings and config files',
    group: 'AROUND THE WORK',
    summary: "What you can change in the Settings window, and what lives in your project's files.",
    blocks: [
      GuideParagraph(
        "Open **Settings** from the top bar (or from the {mod}+K palette). **App** settings are "
        "yours alone: Display, Editor, XP, Notifications, Usage and System. **Project** settings "
        "belong to one project: Git, Setup, Gate, Agent, Roles, Environment and Instructions.",
      ),
      GuideHeading('The project files'),
      GuideTerms([
        (
          '.haro/settings.toml',
          "The shared settings, committed with your project: setup and run commands, the test "
              "runner, agent limits.",
        ),
        (
          '.haro/settings.local.toml',
          "Your own overrides. These aren't committed.",
        ),
        (
          '~/.haro/settings.toml',
          "Defaults for every project on your machine.",
        ),
        (
          '.haro/instructions.md',
          "A standing note that every agent run reads. It's guidance, not a rule, unlike the "
              "tests.",
        ),
      ]),
      GuideBullets([
        "The **setup** command runs when a workspace is created, for example to install "
            "dependencies.",
        "The **run** command starts your app. It should use the port haro gives it, available "
            "as `HARO_PORT`, so workspaces never collide.",
        "Secrets belong in **Settings > Environment**, not in the repo.",
        "Agent limits include a spend cap per run, a warning when spending adds up, how many "
            "agents may run at once, and a review limit (how many workspaces can wait before "
            "haro nudges you).",
      ]),
      GuideSeeAlso(['gate', 'run-app']),
    ],
  ),
  GuideTopic(
    id: 'xp',
    title: 'XP, rank and streak',
    group: 'AROUND THE WORK',
    summary: "A light scoreboard that rewards work you did by hand. You can switch it off any time.",
    blocks: [
      GuideParagraph(
        "You earn points for useful things: reading docs, making a plan, a green test run, "
        "looking over a diff, and merging on green. Work you wrote by hand the whole way pays "
        "more and builds a **streak**, counted in days with a by-hand green merge. Anything an "
        "agent touched pays the smaller amount.",
      ),
      GuideBullets([
        "The ranks are Novice, Journeyman, Craftsman and Master.",
        "Nothing pays for a red or blocked run, and XP never gets in the way of a merge.",
        "You can switch it off, or change the reminder, in **Settings > XP**.",
      ]),
    ],
  ),
  GuideTopic(
    id: 'help',
    title: 'Quick answers',
    group: 'AROUND THE WORK',
    summary: "The questions people run into first.",
    blocks: [
      GuideTerms([
        (
          "My agent won't start.",
          "It may be waiting: setup could still be running, or too many agents are already "
              "working (the stream says which). A Manual workspace has the agent switched off "
              "on purpose, so switch the mode at the top.",
        ),
        (
          "The gate is red but every test passed.",
          "A safety check blocked it. The Review step names it: coverage, a merge that doesn't "
              "apply cleanly, or a weaker test.",
        ),
        (
          "The gate says it couldn't run.",
          "Setup failed. Read the banner, fix the problem, and press **Re-run setup**.",
        ),
        (
          "Where are my files?",
          "Each workspace is a real folder. Use **Open in…** to open it in your editor. haro "
              "keeps its own data in `~/.haro`.",
        ),
        (
          "Does haro send my code anywhere?",
          "haro itself has no server and sends nothing to one. The agent sends what it reads to "
              "the AI it uses: Claude through your own login, or the model on your own machine if "
              "you chose that. GitHub is used when you open or check pull requests, through your "
              "own GitHub login. Everything else haro does, like running tests, stays on your "
              "computer.",
        ),
        (
          "I closed haro while something was running.",
          "Quitting stops the agent and the tests (haro asks first if work is running). Your "
              "files stay in their workspace.",
        ),
        (
          "How do I see the shortcuts?",
          "Press ? anywhere, or open this window and pick the Keyboard shortcuts tab.",
        ),
      ]),
    ],
  ),
];
