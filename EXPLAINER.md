# A Long Walk Through Building Android

*What happens when you type `m`, why the build is the shape it is, where every second goes, what makes the inner loop fast, what every other build system does instead, what Bazel-for-Android attempted, why it didn't ship, and how AOSP could plausibly get to millisecond inner loops.*

---

This is a long document. It is meant to be read slowly. I have tried to write it so that someone who has programmed a little and has heard of compilers, but who has never opened the AOSP source tree, can finish it and come away knowing more about how Android is built than most engineers who ship Android for a living.

There is no jargon I do not define. The first time a term shows up that you might not know, it is defined in the same paragraph, and it also has an entry in the glossary at the end. If something feels obvious, skim that section. If something feels opaque, that is a writing bug, not your problem; tell me, and I'll fix it.

The structure roughly mirrors how I learned the material. Part I is the problem at the highest level: what is a build, why is it hard at Android's scale. Parts II—V are the machinery of the actual AOSP build (Make, Ninja, Kati, Soong/Blueprint) explained from scratch, with real examples and real code. Part VI is the cost breakdown — where every second of a build actually goes. Part VII is the Java pipeline (javac, metalava, R8, dexpreopt) and where its time goes. Part VIII is why incremental analysis is hard. Part IX is what I tried, with code. Part X is the proposed designs that could plausibly get the inner loop to milliseconds, end to end. Part XI compares to other build systems in detail. Part XII is the Roboleaf postmortem — Google's serious attempt to migrate Android to Bazel, and why it didn't ship. Part XIII is the strategic synthesis. The glossary is at the end.

There is also a one-page "spine" in Part V that walks through *literally everything that happens* when you type `m frameworks/base`. If you have ten minutes, read that.

---

## Enabling the warm path, and what is actually verified

This repo ships a working **warm-incremental `soong_build`**: edit one `Android.bp`,
regenerate `build.ninja` in seconds, byte-identical to a clean build. It is one
environment variable on an otherwise-normal build:

```sh
# First build: cold. Starts the resident soong_build daemon, snapshots the graph.
SOONG_PERSISTENT_REUSE_GRAPH=true m nothing
#   …edit an Android.bp…
# Re-run the SAME command: warm. Reuses the resident graph, O(edit), byte-identical.
SOONG_PERSISTENT_REUSE_GRAPH=true m nothing
```

**The whole feature is gated behind that variable.** With it unset — the default,
and what every normal build does — the code takes the stock path and the manifest
is byte-for-byte identical to upstream Soong. The upstream Blueprint unit tests
pass unchanged. So merely applying the patch does not change a normal build,
including a Kati-enabled Pixel `m`.

**What was verified:** `aosp_cf_x86_64_phone-trunk_staging-userdebug`, **soong-only**
(`m nothing`), property-edit / add / remove on `frameworks/base/Android.bp`, warm
output `cmp`-identical to a cold resident rebuild of the same tree.

**What was NOT verified (honest residual risk):** Kati-enabled full `m`; vendor /
proprietary modules; larger graphs and extra `PRODUCT_SOONG_NAMESPACES`; any
non-`aosp_cf` product. The design fails *safe* there, not *wrong*: anything the warm
path can't represent incrementally returns `ErrFallbackToFullBuild` and does a full
cold rebuild (byte-identical to stock), logging a greppable `WARM-FALLBACK: <reason>`.
To trust a new edit class on your tree, run the warm edit, then a
`SOONG_PERSISTENT_REUSE_GRAPH=true` cold rebuild of the same tree, and `cmp` the
shards. Part IX has the mechanism; Part X has what remains.

---

## Table of Contents

* **Prologue.** Why this is a book.
* **Part I — The problem**
    * 1. Hello world's hidden complexity
    * 2. When one file becomes a thousand
    * 3. Why AOSP is unusual
    * 4. The dependency graph, your friend forever
* **Part II — A brief history of build systems**
    * 5. Before Make: humans bookkeeping by hand
    * 6. Make (1976) and its revolution
    * 7. Where Make strains
    * 8. A decade of alternatives
    * 9. Ninja's insight: separate analysis from execution
* **Part III — Ninja, the executor**
    * 10. Anatomy of a tiny ninja file
    * 11. How Ninja runs a build
    * 12. depfiles, restat, dyndeps — the subtle bits
    * 13. The AOSP manifest: gigabytes of text
* **Part IV — Kati, the remaining Make**
    * 14. Why Kati exists
    * 15. What Kati does today
* **Part V — Soong and Blueprint**
    * 16. What Soong is
    * 17. A first Android.bp file
    * 18. Modules and module types
    * 19. Variants — Android's multiplication problem
    * 20. Mutators — the assembly line
    * 21. Providers — how modules talk
    * 22. GenerateBuildActions — the ninja faucet
    * 23. Singletons — whole-graph aggregators
    * 24. Manifest assembly
    * 25. **The spine: what `m frameworks/base` really does, step by step**
* **Part VI — Where the time goes**
    * 26. Cold-build cost breakdown
    * 27. Why startup is slow
    * 28. Why a `.bp` edit costs more than it should
    * 29. The soong_ui floor
    * 30. The Kati floor
    * 31. The Soong analysis floor
    * 32. The ninja-write floor
    * 33. The ninja-execute floor
* **Part VII — The Java pipeline and friends**
    * 34. javac: still here, still slow
    * 35. Metalava: the SDK API checker that eats minutes
    * 36. R8 and shrinking
    * 37. d8 and dexing
    * 38. Header jars and Turbine
    * 39. Resource processing (aapt2)
    * 40. AIDL/HIDL codegen
    * 41. APEX assembly
    * 42. dexpreopt
* **Part VIII — Why incremental analysis is hard**
    * 43. The six structural obstacles
    * 44. Mutators revisited
    * 45. Singletons revisited
    * 46. Providers and propagation
    * 47. Accumulated state (dedup, naming, position)
    * 48. The faithfulness problem
* **Part IX — What I tried**
    * 49. The byte-verification corpus
    * 50. Fix 1: faithfulness baseline
    * 51. Fix 2: non-destructive content-addressed dedup
    * 52. Fix 3: deterministic package names
    * 53. Fix 4: precise propagation via interfaceChanged
    * 54. Fix 5: delta write keyed on the regenerated set
    * 55. Fix 6: position-shift re-serialize
    * 56. The standalone engine (build/blueprint/incr)
    * 57. Things I tried and reverted
* **Part X — Proposed designs: a real path to millisecond overhead**
    * 58. Incremental singletons as folds
    * 59. File-scoped reparse
    * 60. Caching the soong_ui outer work
    * 61. Per-module action cache, fully enabled
    * 62. Pure-function invariant by construction
    * 63. Remote analysis cache
    * 64. Content-addressed action cache (Bazel/Buck2 style)
    * 65. Sandboxed, hermetic actions
    * 66. The strangler-fig migration: replacing module types one at a time
    * 67. Persistent javac/metalava daemons
    * 68. RBE plus distributed analysis: the day when even cold is fast
* **Part XI — How other build systems do it**
    * 69. Make
    * 70. Bazel and Starlark
    * 71. Buck2 and DICE
    * 72. Nix
    * 73. Shake
    * 74. Tup
    * 75. Pants
    * 76. Gradle
* **Part XII — Roboleaf: the Bazel-for-Android attempt**
    * 77. What Roboleaf was
    * 78. What it shipped
    * 79. What stalled it
    * 80. What we learned
* **Part XIII — Strategic synthesis**
    * 81. The pure-function invariant, one more time
    * 82. Tactical vs strategic
    * 83. Where I would invest if it were my money
* **Glossary**

---

## Prologue. Why this is a book.

Imagine you have built a program. You typed:

```sh
gcc hello.c -o hello
```

A few seconds later, a working executable appeared. That is a build. It was easy because there was almost nothing to do. One file in, one file out. The C compiler did the only interesting thing: it turned your text into machine instructions. You did not need to tell it what order to do things in, because there was only one thing to do. You did not need a build *system*. You needed a build *step*.

Now imagine instead that you are building all of Android. Not an app *on* Android — the operating system itself: the kernel, the hundreds of platform libraries that make up the framework, the run-time, the package manager, every preinstalled system app, every prebuilt binary, every test suite, every configuration for every kind of phone and tablet that ships Android. A single phone product is a few hundred megabytes of output, but to get there, the build executes on the order of half a million separate compiler invocations, linker invocations, packaging steps, code generators, signing tools, and house-keeping commands. A fresh AOSP checkout, the first time you build it on a fast workstation, runs for **hours**.

When you change one Java file and ask the build system to give you your change back as quickly as possible, what you are really asking is: of those half a million commands, find the few hundred (or few tens, or perhaps just one) that actually need to be redone, and run only those. Anything else is wasted time.

That is the whole problem of building Android well. The naive thing — redoing everything from scratch — takes hours. The smart thing — redoing only what needs to be redone — can in principle take seconds. The gap between "in principle seconds" and "still many minutes in practice" is what people have been working on, in build systems, for fifty years. This document is about that gap, in the specific shape it takes for Android.

Three things make this gap unusually hard for Android in particular:

1. **The build is enormous.** Tens of millions of lines of source. Tens of thousands of logical *modules* (a module is a logical chunk of code that produces an artifact like a library or an app; we'll define the term properly later). Several hundred different *module types* — C libraries, Java libraries, APKs, APEXes, image partitions, prebuilts, and so on. The framework alone, the giant pile of Java that defines what "Android" *is* to apps, is itself one of the larger pieces of software ever assembled.

2. **The build is multiplied.** Android runs on many architectures (arm, arm64, x86, x86_64), against many SDK levels (the current API, the previous one, the one before that), in many roles (target device, build host, APEX-internal, recovery image, vendor partition), and on multiple OSes (when building build-time tools that have to run on Linux *and* macOS). A single library declaration in a config file expands, inside the build system, into dozens of *variants* that all need to be built and kept consistent with one another.

3. **The build is iterative.** Engineers do not just build Android once. They edit one file, build, push to a device, look at the result, change a line, build again, push, look. If each cycle of that loop is thirty seconds, they can stay in flow. If it is three minutes, they batch changes, lose context, get distracted, and ship more bugs. Making the inner loop fast is not a nice-to-have; it is the highest-leverage piece of infrastructure work in the company. Whole engineering teams exist solely to do this.

The AOSP build, as it stands today, is the third generation. The first generation was *Make*, the venerable Unix build tool from 1976, applied with great discipline but eventually strained by Android's scale. The second generation was *Soong-on-top-of-Make*, a hybrid where a new declarative analyzer (Soong) ran alongside the existing Make infrastructure. The third, current generation is *Soong-with-Kati-glue*: Soong does almost all the analysis, Kati (a faster Make implementation) handles a thin edge, and Ninja (a small, fast build executor) runs the commands. We will meet all of these tools in detail.

Before we do, one promise: I will not use jargon without first defining it. If you bump into a term that has not been defined yet, that is a bug in my writing, not a gap in your knowledge.

Let's start at the beginning.

---

# Part I — The problem

## 1. Hello world's hidden complexity

When you compile a hello-world program, what really happens?

You typed:

```sh
gcc hello.c -o hello
```

The C compiler (gcc here) reads `hello.c`. Internally it runs four stages.

**Preprocessor.** The preprocessor walks through the source and handles every line starting with `#`. When it sees `#include <stdio.h>`, it copies the entire content of `stdio.h` into the input stream at that point. When it sees `#define MAX 10`, it remembers the macro and substitutes `10` for `MAX` everywhere later. After the preprocessor runs, the source code looks much longer than what you typed: most of the C standard library's declarations have been inlined.

**Compiler proper.** The compiler turns this fully-expanded C source into assembly language — low-level instructions specific to your CPU architecture (x86_64 instructions, or arm64 instructions, or—).

**Assembler.** The assembler turns the assembly text into raw machine code: the actual binary bytes the CPU executes.

**Linker.** The linker takes the machine code, finds every external symbol your program references (like `printf` from the C standard library), and stitches in the addresses where those symbols live, so that at run time the calls find their destinations.

The output, `hello`, is an executable. It is roughly 30 KB on a typical Linux system. Almost none of those 30 KB are your code; they are boilerplate the toolchain glued in. Your actual program is probably 200 bytes of machine code, plus a lot of standard library and runtime metadata.

This is a build. It is also a build *system*, in miniature: gcc is the build system. It read one input, decided which stages to run, fed each stage's output into the next, and produced a final artifact. It even did some implicit caching — if you compile the same file twice in a row, the OS's file cache makes the second one slightly faster.

Now ask the interesting question: what happens with **two** source files?

```sh
gcc hello.c util.c -o hello
```

That works. gcc happily compiles both, links them, you get a program. But notice: gcc, given the same command, does the *same work every time*. If `util.c` has not changed and you only edited `hello.c`, gcc still recompiles `util.c`. That is wasteful. With two files, nobody notices. With twenty thousand files (the real Android framework), that is the difference between a build that takes a few seconds and a build that takes an hour.

The realization, around 1976, that this was a problem worth solving properly led to the first build system that anyone outside its inventor cared about: Make.

## 2. When one file becomes a thousand

A build system is a program whose job is to:

1. Read a description of what you want to build.
2. Figure out the right order to do things in, based on what depends on what.
3. Notice, when you re-run it, which inputs have changed since the last build, and redo only the affected work.
4. Run the actual compile, link, and packaging commands.

Step 3 is the magic. The build system's claim to fame, the reason it exists, is that it can *skip work it has already done*. Everything else flows from that.

To know what to skip, the build system needs to track, for every output file it ever produces, which input files contributed to it. If you edit `util.c`, the build system needs to know: *"to rebuild hello, I need util.o; to make util.o, I need util.c; util.c changed; therefore I must rebuild util.o, and then hello."* Conversely, if you edit something completely unrelated — say, a comment in a third file the program doesn't even include — the build system needs to know: *"that file does not feed into hello in any way; do nothing."*

This bookkeeping is captured by the *dependency graph*, a phrase that sounds more abstract than it is. Let's draw it.

```
hello.c     util.c     stdio.h
   |          |          |
   v          |          |
hello.o    util.o
   \         /
    v       v
       hello
```

Arrows go from inputs to outputs (or equivalently, "is read by"). Each node is a file. Each edge means *"if the source changes, the target might need to be remade."* The whole structure is a **graph** in the mathematical sense: nodes connected by directed edges. It is also **acyclic** — no cycles — because a cycle would mean a file depended on itself, which is meaningless: how can you make `hello` if making `hello` requires `hello` already to exist?

The technical name is **DAG** — *directed acyclic graph*. It comes up constantly in build-system writing because the DAG is the central object every build system manages.

The job of every build system, at its core, is: *maintain the DAG, walk it in dependency order on each build, redo only the parts whose inputs have changed.*

Make, written by Stuart Feldman at Bell Labs in 1976, was the first widely successful build system in this style. Make's input file is called a Makefile. Here is what one looks like for our two-file program:

```make
hello: hello.o util.o
	gcc hello.o util.o -o hello

hello.o: hello.c
	gcc -c hello.c

util.o: util.c
	gcc -c util.c
```

You can read this top to bottom in English: "to make `hello`, you need `hello.o` and `util.o`; once they exist, run this command. To make `hello.o`, you need `hello.c`; run this command. To make `util.o`, you need `util.c`; run this command."

The lines after the colons are the **dependencies**. The indented lines are the **commands** to run. Make reads this whole file, builds the DAG in memory, looks at file modification times (`hello.c` was last modified at 3:14pm; `hello.o` does not exist yet; therefore `hello.o` is out of date and must be made), and runs the right commands in the right order.

That is Make in its core idea. It looks tiny and obvious now. In 1976, it was a small revolution.

## 3. Why AOSP is unusual

If Make is so simple, why isn't Android still built with it?

It largely *was*, for over a decade. The Android source tree started out with thousands and thousands of Makefiles, one per directory or so. Each Makefile told Make how to build the modules in its directory: this is a Java library, here are the sources, here are the dependencies, here is what its output should be called. The Android build team wrote an enormous wrapper of conventions on top of Make — things like `BUILD_JAVA_LIBRARY`, a Make macro that expanded into all the boilerplate needed to compile a Java library, link it, package it, and install it. Engineers wrote a few lines per module, and the wrapper turned them into the actual Make commands.

It worked. It was also, eventually, miserable. Three things made it worse, faster and faster, as Android's scope grew.

**First, parsing the Makefiles took longer and longer.** Make has to read its whole input file before doing anything. By the late 2010s, just parsing the Android Makefile graph — starting from the top, including every product config Makefile, every device Makefile, every `Android.mk` file recursively, every shared macro — took several **minutes**, before any actual compilation could start. On every build. Engineers would type `m` and walk to the coffee machine. By the time they returned, the build had finally begun compiling.

**Second, Make is fundamentally a shell-based imperative tool.** Inside a Makefile, the "commands" are shell scripts, and Make itself supports its own little language for setting variables, evaluating expressions, running shell substitutions, doing string manipulation. It is Turing-complete in the small. This gives it enormous expressiveness — you can do almost anything in a Makefile — but it also means that knowing what a Makefile will *do* requires actually running it. There is no static analysis. There is no "show me all modules" answer that doesn't involve interpreting the whole Make program. Tooling around Makefiles is therefore impossible to build well. IDE support is hopeless. Refactoring is hand-eye-coordination.

**Third, Make's mental model is files.** Make thinks in terms of files that depend on other files. Android's mental model is *modules*. An Android module is a logical entity — a library, an app, a configuration. A module produces files, but the module itself is not a file. Most of Android's actual structure — "this library is part of *this* APEX, versioned for the system image, with *this* SDK level, sanitized" — has no clean way to be expressed in file terms. The Android-on-Make infrastructure ended up generating *marker files* just to satisfy Make's worldview that "X depends on Y" means "Y must exist as a file." The marker file existed only to be touched.

These problems compounded. By about 2015, internal Google teams were spending substantial fractions of their engineering hours fighting the Make-based build. Touch one `Android.mk`, lose ten minutes to the incremental rebuild. Change a global flag, lose forty minutes. Add a new module type, write hundreds of lines of macros that no one else fully understood.

The fix had to come from rethinking the build, not patching it. Around 2016, Google started writing a new analyzer called **Soong**. Soong is written in Go, reads a declarative file format (`Android.bp` instead of `Android.mk`), and emits a Ninja manifest. Most of this document is about how Soong works and the consequences of its design choices.

But before we get to Soong, we need to understand the world Soong lives in — which means understanding the executor that actually does the work after Soong has decided what should happen: **Ninja**.

## 4. The dependency graph, your friend forever

We drew a tiny dependency graph in chapter two. Stare at it again, because everything about building is going to come back to this shape.

A real build's DAG has tens of thousands of nodes and tens of millions of edges. It is not human-readable. But its structure is the same as the tiny one:

* Each node is something that can exist or not (a file, or an abstract output).
* Each edge says "to make this, I need that first."
* The whole thing is acyclic.

A build system's loop, every time you ask for a build, is:

1. Look at the leaves of the DAG (the sources you wrote). Note anything that has changed since the last build.
2. Walk upward through the DAG. Any node downstream of a changed leaf is *potentially* stale.
3. Run the rebuild commands in dependency order, parallelizing where the DAG permits.

That last word is doing a lot of work. The DAG tells you not just what *order* to rebuild things in, but also what *cannot* be done in parallel. If A depends on B, B must finish before A can start. But two siblings, neither depending on the other, can run at the same time. A good executor exploits this aggressively. Ninja, the executor Android uses, often runs hundreds of commands in parallel on a multi-core machine.

The interesting thing about the DAG is that it is not directly written down. The user doesn't draw it; the `Android.bp` files don't draw it explicitly. It is *inferred* by the build system from the descriptions you provide. Each module says "I depend on these other modules" and "I produce these outputs," and the build system stitches those statements together.

This is harder than it sounds. Most languages have *implicit* dependencies that the build description does not capture. When you write `#include <header.h>` in C, you create a dependency that no human-written Makefile sees. The C compiler discovers it at compile time. Build systems have to handle this with care. Make has a mechanism called *depfiles* (side-channel files the compiler emits during compilation) to handle exactly this. Ninja, which we will get to, has the same mechanism, and uses it everywhere.

The DAG is also not static. Some build operations *create* new dependencies. A code generator might emit a list of files that are knowable only after the generator has run. Soong, Bazel, and other systems all have machinery for this kind of *dynamic dependency*, and we will see how Soong's version works.

Hold onto the picture of the DAG, because every difficult thing in this document is a question about how to manage the DAG efficiently when it is enormous and most of it does not change on a typical edit.

---

# Part II — A brief history of build systems

## 5. Before Make: humans bookkeeping by hand

In the early 1970s, building software meant keeping track, by hand, of which source files needed to be recompiled when. The system administrator wrote shell scripts. The scripts said: "compile these files, then link them in this order." If something failed, you fixed it and re-ran the script. There was no automatic dependency tracking.

The shell-script model has one large virtue: simplicity. It has two large vices. It is **slow**, because the script redoes the whole build every time. It is **fragile**, because the ordering in the script encodes information that is also encoded in the source via `#include` (or its equivalent), and the two can drift out of sync silently. The bug looked like this: you'd edit a header, forget to recompile a file that included it, and ship code that compiled against a stale view of the header. When the bug showed up in production, you'd spend half a day finding it.

The state of the art in 1975 was that programmers built software by hand. If you changed `util.c`, you knew to recompile `util.c` and link. If you changed a header, you knew which files included it and you recompiled those. This worked at ten-file scale. It did not work at hundred-file scale, and Bell Labs projects were already past hundred-file scale.

The folkloric version of Make's invention is that Stuart Feldman, a researcher at Bell Labs, watched a colleague spend an afternoon hunting down a bug that turned out to be a stale object file — a `.o` he had forgotten to rebuild when he changed its `.c` source. The bug took half a day; the real bug, the legend goes, was that the build was being done in people's heads, and so Feldman wrote Make to automate the bookkeeping. Feldman's own 1979 paper (*Software—Practice and Experience*) doesn't claim a weekend; the "weekend" detail is later embellishment. What we do know is that Make first shipped in 1977 as part of the Unix Programmer's Workbench.

## 6. Make (1976) and its revolution

Make's core insight, in 1976, was the marriage of two ideas:

* A *declarative* dependency description: "A depends on B, C, and D."
* An *imperative* command description: "to remake A, run this shell command."

Combining them meant the programmer wrote down **what** depended on what, and **how** to rebuild, but the **scheduling** was Make's problem. Make figured out, given file modification times, which targets needed to be remade, what order to remake them in, and which steps could be skipped.

A Makefile looks like this (we saw it before):

```make
hello: hello.o util.o
	gcc hello.o util.o -o hello

hello.o: hello.c
	gcc -c hello.c
```

The line `hello: hello.o util.o` is a **rule**. The colon separates the **target** (left side: the thing you can make) from the **prerequisites** (right side: what it depends on). The line below it, indented with a literal TAB character (this matters painfully — spaces will not work, an early Make-ism that has confused beginners for forty-eight years), is the **recipe**: the shell command to run.

When you type `make hello`, here is what happens:

1. Make parses the Makefile.
2. Make looks at the target `hello`. It depends on `hello.o` and `util.o`. Are those up to date?
3. To check, Make recursively looks at their rules. `hello.o` depends on `hello.c`. Make looks at the modification time of `hello.c` (say 3:14pm) and `hello.o` (3:00pm). `hello.c` is newer. So `hello.o` is stale.
4. Make runs the recipe to remake `hello.o`: `gcc -c hello.c`.
5. After it runs, Make checks `hello.o`'s timestamp again. It is now newer.
6. Make does the same for `util.o`. Maybe it's already up to date.
7. Now `hello.o` and `util.o` are both up to date. Make runs the recipe for `hello`: `gcc hello.o util.o -o hello`.

That's Make in its essence. It invented features over the years — pattern rules, automatic variables, conditionals, includes — but the core was already this in the original version.

For about twenty years, this was *the* way to build software on Unix. The phrase "write a Makefile for it" was a verb. Generations of C programmers internalized Make's idioms. Make is still everywhere, and still works well for projects of modest size.

It started to creak as projects scaled past a certain point. Let me explain exactly what went wrong.

## 7. Where Make strains

Make has four weaknesses that bite at scale, and all four bit Android hard.

**One — timestamps lie.** Make decides whether a file is out of date by comparing modification times. ("mtime" is filesystem shorthand for *modification time* — the moment the OS thinks the file was last written, recorded as a number of seconds since 1970.) If the source has a newer mtime than the target, the target is stale. Simple and fast. Also wrong in subtle ways.

`touch` a source file (update its modification time without changing content) and Make will rebuild even though nothing changed. Conversely, if a file's mtime is set back in time (this happens with version-control checkouts, NFS, container builds where files are unpacked all-at-once), Make will fail to rebuild when it should. File systems with second-resolution timestamps can fail to detect edits that happen within the same second.

Modern build systems use *content hashes* (or fingerprints) instead of mtimes: they hash the bytes of each input and use the hash as the file's "version." A touch doesn't change the hash. The system is robust against time-travel. Make never adopted this; some variants did, but classical Make didn't.

**Two — dependencies are manual.** In a Makefile, dependencies are listed by hand. If you write

```make
foo.o: foo.c
```

and `foo.c` includes `"extra.h"`, Make doesn't know that. If you edit `extra.h`, Make does not realize `foo.o` is stale; it cheerfully says "nothing to do" and your program ships with stale code.

Real-world Makefiles deal with this in one of two ways: either you list every include dependency by hand (tedious; goes out of sync; nightmare in C++), or you use auto-generated **depfiles** — side files the compiler emits, declaring what it actually read. Make can `include` these. It works, but it is a band-aid. You can forget to wire it in. Various Makefile patterns get it wrong in subtle ways. "Missing dependency" is a Make classic.

**Three — recursive Make breaks the DAG.** To structure a big project, the Make convention was *one Makefile per directory*, with the top-level Makefile calling sub-Makefiles via `$(MAKE) -C subdir`. Each subdirectory knew about its own files, not the broader tree.

The problem: when the top Make runs sub-Make in directory A, which depends on the output of sub-Make in directory B, the top Make does not actually know about the cross-directory dependency. You have to write it manually. If you forget, you get half-built results that work locally but break in CI.

This problem has been written about extensively. Peter Miller's 1997 paper, **"Recursive Make Considered Harmful"**, is the canonical reference. The proposed fix is to have *one* Makefile for the whole project that `include`s all the sub-Makefiles, so Make sees the whole DAG. That works, but the resulting Makefile is gigantic and slow to parse.

**Four — Make parses slowly at scale.** Make has to read its whole Makefile before doing anything. For Android-sized Makefile graphs (millions of lines after `include` expansion), this took multiple minutes per build invocation. Even incremental builds where nothing had changed paid this parse cost.

Several attempts to fix this — distributed parsing, partial reuse of prior parses — were made. None stuck. Make's fundamental model is "every build, parse the world." For a small project, free. For Android, a wall.

These four weaknesses, together, were the motivation for the next generation of tools.

## 8. A decade of alternatives

Between Make's heyday and the present, dozens of alternative build systems were tried. A short, opinionated tour.

**Autotools** (autoconf + automake + libtool, mostly 1990s). The classic GNU build system. Autotools generates Makefiles, so it inherits all of Make's weaknesses, plus a layer of M4 macro indirection. Famously hard to debug. Still used by tens of thousands of open-source projects because that's what they were set up with.

**Ant** (2000). Java-oriented. XML-based build files. Solved the "manual dep tracking is awful for Java" problem by giving Java people a Java-aware tool. Less general than Make, but worked well in its niche.

**SCons** (2001). Python as the build language. The build description *is* Python. Powerful, flexible, slow at scale. The "Python is the build language" idea has resurfaced many times.

**CMake** (2001). Cross-platform build configuration. The user writes CMake files; CMake generates Makefiles (or Visual Studio projects, Xcode projects, Ninja files) for the current platform. Effectively a *configuration* step producing a build description for some other tool to run. CMake's `CMakeLists.txt` is itself a small domain-specific language. CMake is everywhere in cross-platform C++.

**Gradle** (2008). Build tool for Android *apps* (not the platform!) and Java in general. Groovy or Kotlin as the build DSL. Has its own incremental build engine, daemon, caching system. Powerful and complex. The dominant build tool for Android apps today. Note carefully: Gradle builds *apps* on Android. The platform itself is built with Soong + Ninja.

**Ninja** (2010). We'll spend a whole chapter on this. The executor AOSP uses.

**Bazel** (2015). Open-sourced version of Google's internal Blaze. Heavy discipline: rules in Starlark (restricted Python), hermetic actions, remote caching. Whole chapters later.

**Buck / Buck2** (Facebook/Meta, 2013 / 2023). Originally Bazel-like, written in Java. Buck2 is the 2023 Rust rewrite with a deep incremental computation core called **DICE**. Buck2 is probably the most sophisticated incremental build system in production today.

**Please, Pants, Bazelisk, Nix, Shake, Tup, Memoize, Redo, —** The taxonomy could go on for chapters. The summary is: build systems have been moving steadily in three directions for fifty years:

* From *imperative* descriptions (Makefiles, shell) toward *declarative* descriptions (Bazel BUILD files, Soong `Android.bp`).
* From *timestamp-based* change detection toward *content-hash-based*.
* From *monolithic* parsers toward *incremental* ones that remember most of their work between invocations.

Every modern build system, including Soong, is on this trajectory. Soong's particular blend of choices (declarative front, imperative middle in Go, Ninja as the executor) is the focus of this document.

## 9. Ninja's insight

Ninja was invented around 2010 by Evan Martin, a Google engineer working on Chromium. Chromium's build was huge and was being driven by a tool called GYP, which generated GNU Makefiles. Even a no-op rebuild on Chromium took on the order of ten seconds in Make (Evan's original blog and his talk on Ninja's design quote a range; numbers depended on the workstation, but ten seconds is the figure most often cited), almost all of it Make parsing the giant generated Makefile.

Evan's insight: nobody needs the executor to be smart. The executor needs to be fast. Make tried to be both, and the result was a language complex enough to be slow to parse and simple enough that anyone with a clever idea reached for it. Ninja flipped this. Ninja would be **dumb**: it would do less. Specifically:

* Ninja would not be a programming language. No conditionals, no loops, no expressions in the build description.
* Ninja would not try to write the build description itself. *Someone else* (another tool, a configuration step) would emit the Ninja file.
* Ninja would just execute. It would read the description, build the DAG, decide what was out of date, run commands in parallel.

This narrowness was its strength. Ninja's parser is small and fast. Its executor is small and fast. It does not try to understand C or Java; it just runs commands. The build descriptions it accepts are designed to be machine-generated, not human-written — which is why they look like a no-frills assembly of three or four constructs.

In retrospect, this division of labor — *configuration* as one phase, *execution* as another — was the most influential idea in build systems since Make itself. The same idea recurs in almost every modern system: CMake configures, then Make or Ninja runs; Bazel analyzes (via Skyframe), then an in-process executor runs the actions; Soong analyzes, then Ninja executes. Bazel's executor isn't actually "Ninja-like" under the hood — it's its own action graph with its own scheduling — but the architectural split between *figuring out what to do* and *doing it* is shared.

---

# Part III — Ninja, the executor

## 10. Anatomy of a tiny ninja file

Here is what a small Ninja file looks like:

```ninja
rule cc
  command = clang $cflags -c $in -o $out

rule link
  command = clang $ldflags $in -o $out

build out/hello.o: cc src/hello.c
  cflags = -O2 -DRELEASE

build out/util.o: cc src/util.c
  cflags = -O2 -DRELEASE

build out/hello: link out/hello.o out/util.o
  ldflags = -lc -lm
```

If you've never read Ninja before:

* `rule cc` defines a **template**. The `command` is what gets run. `$cflags`, `$in`, `$out` are placeholders that get substituted at build time.
* `build out/hello.o: cc src/hello.c` is a **build edge**: "to make `out/hello.o`, run the `cc` rule on `src/hello.c`." After it, indented, are per-edge variable overrides (`cflags` here).
* The file is read by Ninja, the DAG is built (`hello.o` depends on `src/hello.c`; `hello` depends on `hello.o` and `util.o`), and Ninja runs the commands in dep order, in parallel where possible.

That's basically the whole language. No flow control. No conditionals. No functions. There is a `subninja` keyword for splitting files but it's strictly for organization, not control flow.

The AOSP build's Ninja file — the one Soong generates — is, today, around **5.6 gigabytes** of text on a current `aosp_cf_x86_64_phone-trunk_staging-userdebug` build. Most of that bulk is in `build.aosp_cf_x86_64_phone.incremental.ninja`, the subninja holding the incrementally-supported modules' build actions — around 2.9 GB on its own before it is sharded. It is split into **shard** files via `subninja`, so Soong can write them in parallel. The shard count is configurable via the `SOONG_NINJA_SHARDS` environment variable (10, 50, and 200 are all in use). Each shard contains the build statements for a hash-bucketed subset of modules. There is also one file for "singleton" outputs, one for "phony" aggregators, and one for incremental-supported modules. Re-measure on your own tree before quoting any of these numbers; they vary with the tree and the shard count, and they drift as the tree grows.

## 11. How Ninja runs a build

Once Ninja has read the manifest:

1. **Parse.** Ninja parses the whole manifest (and any subninja includes) into an in-memory representation. For AOSP's ~5.6 GB manifest, this takes about 5 seconds on a warm near-no-op edit.
2. **Load state.** Ninja loads its build log (`.ninja_log`) and its dependency log (`.ninja_deps`). These record what happened in past builds: what commands ran, what hashes (or mtimes) inputs had, what deps the compiler-emitted depfiles declared.
3. **Scan for dirty edges.** Ninja walks the DAG from the targets you asked for, back through dependencies. For each edge, it checks whether the output exists, whether the input mtimes have changed vs the log, and whether the command line has changed vs the log. If anything has, the edge is dirty.
4. **Schedule.** Ninja builds a worklist of dirty edges, respecting dep order. It uses a pool of worker processes (the `-j` flag) to run them in parallel.
5. **Run commands.** As each command finishes, Ninja parses its emitted depfile (if any), updates the dep log, and unlocks downstream edges. On failure, Ninja stops scheduling new work but lets in-flight commands finish.

The whole thing is fast and parallel. On a typical big incremental build, Ninja's overhead (parse + scan) is a small fraction of total build time; the bulk is spent inside the actual compilers and packagers Ninja is running.

## 12. depfiles, restat, dyndeps

A subtle but important Ninja feature is **restat**. If you mark a rule with `restat = 1`, Ninja knows that the command *might* leave the output unchanged. After the command runs, Ninja stats the output. If its mtime didn't actually change, Ninja considers downstream edges to *not* be invalidated. This is how the AOSP build avoids rebuilding everything every time the user-facing "regenerate ninja file" step runs but produces a manifest identical to last time.

Another subtle feature is **dyndeps** — dynamic dependencies. Some tools emit not just the target but also a small Ninja-formatted file declaring extra inputs and outputs that weren't known until the tool ran. Ninja reads this and dynamically augments the DAG. Useful for things like "this code generator emits a list of header files only discoverable post-generation."

**Depfiles** are the way Ninja handles transitive header dependencies in C. A rule declares `depfile = $out.d`; the command emits `$out.d` listing every file it actually read; Ninja parses this and adds those files as implicit dependencies. This is the canonical solution to Make's "missing dependency" problem.

## 13. The AOSP manifest: gigabytes of text

Worth picturing concretely. After Soong runs cold, the output directory contains roughly:

```
out/soong/build.aosp_cf_x86_64_phone.ninja              ~30 KB   (top-level, just subninjas)
out/soong/build.aosp_cf_x86_64_phone.0.ninja            ~MBs
out/soong/build.aosp_cf_x86_64_phone.1.ninja            ~MBs
...
out/soong/build.singletons.ninja                        ~112 MB
out/soong/build.phonys.ninja                            ~MBs
out/soong/build.incremental.ninja                       ~2.9 GB  (the single biggest piece)
```

Plus a parallel set of files for Kati's contribution. The combined manifest Ninja reads is ~5.6 GB of text. Ninja parses this in about 5 seconds on a fast workstation.

The shard count is a deliberate choice, set via `SOONG_NINJA_SHARDS`. Splitting too few shards loses parallelism on the write side and makes each delta-write rewrite a larger file; splitting too many adds overhead. Counts of 10, 50, and 200 are all in use depending on the tradeoff being tuned.

---

# Part IV — Kati, the remaining Make

## 14. Why Kati exists

AOSP's build is not pure Soong + Ninja. There is still a thin layer of Make in the pipeline. The tool that runs it is called **Kati**, written by Google around 2014.

Kati's job is to read the remaining `Android.mk` and product-config `.mk` files, evaluate them, and emit a Ninja manifest (or a small set of Make-flavored intermediate outputs) for the parts of the build that haven't moved to Soong. As Soong has matured, Kati has shrunk: today its role is mostly product config (loading the `.mk` files that describe what device you're building) and a small amount of packaging glue.

Kati exists because the migration from Android.mk to Android.bp is *almost* but not quite complete. The remaining Make logic is real (boot image assembly, certain product-config workflows, partition layout) and Soong hasn't absorbed all of it. Kati is the bridge.

## 15. What Kati does today

When you build AOSP, the configuration phase looks roughly like:

* **soong_ui** (the outer driver, written in Go) starts up.
* soong_ui invokes **Kati on the product config Makefiles**. Kati reads ~hundreds of `.mk` files describing the product and emits the derived variables (`TARGET_PRODUCT`, `BOARD_VARS`, `PRODUCT_PACKAGES`, etc.). This is the **dumpvars** phase. Takes ~2.5 seconds.
* soong_ui invokes **Soong proper** to read all `Android.bp` files and emit the bulk of the Ninja manifest. Cold: ~131 seconds.
* soong_ui invokes **Kati again** for a small "packaging" pass that handles parts not yet in Soong. Takes ~1-2 seconds.
* The pieces are combined into a single top-level Ninja file.
* Ninja runs.

Kati itself is much faster than GNU Make. But it is still doing Make-style work. It is on the slow path; the Soong path is the fast path. Future plans involve moving more of Kati's residual work into Soong, at which point Kati shrinks further. For our purposes: Kati is a small piece that handles legacy Make logic; it's not where the action is.

---

# Part V — Soong and Blueprint

This is the heart of the document. Soong is where most of Android's build is decided. Spend more time here than on any other part.

## 16. What Soong is

Soong is Android's **build analyzer**. Its job is:

1. Read all `Android.bp` files in the source tree (~14,000 of them on a current `aosp_cf_x86_64_phone` tree).
2. Parse each into a list of module definitions.
3. Apply transformations to the module set (mutators), producing thousands of module variants.
4. For each variant, decide what Ninja text to emit (its "build actions").
5. Run singletons that fold over the whole module set.
6. Write the resulting Ninja manifest.

It is written in Go, by Google's Android build team. Its source lives in the AOSP tree under `build/soong/`. The underlying parser and runtime is a library called **Blueprint**, in `build/blueprint/`. Soong is the application; Blueprint is the engine.

You can in principle build *anything* on top of Blueprint by defining your own module types in Go. In practice, Soong is the only serious user.

## 17. A first Android.bp file

Here is a small but realistic Android.bp:

```bp
java_library {
    name: "framework-foo",
    srcs: [
        "src/main/java/**/*.java",
        ":framework-foo-aidl-srcs",
    ],
    static_libs: [
        "framework-base",
        "androidx.collection",
    ],
    sdk_version: "core_platform",
    defaults: ["framework-module-defaults"],
}

filegroup {
    name: "framework-foo-aidl-srcs",
    srcs: ["src/main/aidl/**/*.aidl"],
}
```

Let's parse it together as a human.

* The file describes two **modules**.
* The first module is of **type** `java_library`. The type tells Soong what kind of thing this is and which Go code in Soong should handle it.
* The module's **name** is `framework-foo`. This is its unique identifier across the whole tree. No two modules can share a name (with one exception, "namespaces," that we won't get into).
* It has a **`srcs`** property: a list. The first entry is a **glob** — "all `.java` files under `src/main/java/`." The second starts with `:` and is a **module reference** — it refers to another module (the filegroup below) whose own srcs will be inlined into this module's srcs at analysis time. This is the basic mechanism by which one module includes another's source files.
* **`static_libs`** lists modules this library depends on statically. Soong resolves those names to other modules at analysis time and uses their outputs (their `.jar` files, here) as inputs to compiling this module.
* **`sdk_version`** is a string property influencing which version of the Android SDK this is built against.
* **`defaults`** is a list of "defaults modules" whose properties get merged into this module's properties. A common pattern: write a `framework-module-defaults` once with common settings, have every framework java_library reference it.

The second block is similar. `filegroup` is a module type whose only real job is to be a named bundle of source files. Anywhere you reference `:framework-foo-aidl-srcs`, Soong substitutes the filegroup's actual srcs.

The .bp syntax is essentially JSON with named blocks and a few extensions. It is parsed by Blueprint into an in-memory tree. From there, everything is Go data structures.

Importantly: there is no code, no conditionals, no arbitrary logic at the `.bp` level. Everything an `.bp` file does is *declare* properties. What those properties *mean* is implemented in Go by Soong.

## 18. Modules and module types

A module is a logical chunk of build output. Different module **types** produce different things:

| Module type | What it produces |
|---|---|
| `java_library` | A `.jar` (Java bytecode) |
| `java_binary` | A runnable JVM application |
| `java_test` | A test jar |
| `android_app` | An APK |
| `android_library` | An AAR |
| `android_test` | A test APK |
| `cc_library_shared` | A `.so` (shared C/C++ library) |
| `cc_library_static` | A `.a` (static C/C++ library) |
| `cc_binary` | A native executable |
| `cc_object` | A `.o` |
| `genrule` | Whatever the command produces |
| `filegroup` | A named bundle of source files |
| `apex` | An APEX archive |
| `prebuilt_etc` | Copies a file to `/system/etc` |
| `python_binary_host` | A host Python tool |
| `rust_library` | A Rust library |
| `aidl_interface` | Generated AIDL stubs |
| `hidl_interface` | Generated HIDL stubs |
| `license`, `license_kind`, `package` | License metadata |
| `soong_config_module_type` | A user-defined module type |

There are 300+ module types total (a fresh `grep -rn 'RegisterModuleType' build/soong/` on the current tree returns 374 hits; counting only the non-test ones it's a few hundred). Each is implemented as a Go struct + handler. The struct describes the properties the module accepts (Soong unmarshals the `.bp` into this struct). The handler implements the `Module` interface, the most important method of which is **`GenerateBuildActions(ctx ModuleContext)`** — where ninja text is actually emitted.

A module has **identity** (its name) and **properties** (the field values from the `.bp` file). After Soong has finished its work, a module also has **actions** (the ninja edges it has emitted) and **providers** (the typed information it exposes to its dependents). We'll meet all of these.

## 19. Variants — Android's multiplication problem

Here is the first deeply Android-specific concept.

A *single* module declaration in your `Android.bp` can produce *many* actual module instances inside Soong, one per **variant**.

Why? Because Android builds the same library for different targets at once. For one `cc_library_shared`:

* The arm variant.
* The arm64 variant.
* The x86 variant (for emulators).
* The x86_64 variant (for emulators).
* The host variant (for build-time tools).

For a `java_library`:

* The `android_common` variant (regular Android runtime).
* The `android_common_apex31` variant (when included in an APEX targeted at API 31).
* The `android_common_apex33` variant.
* The `android_common.stubs` variant (a stripped-down API-only jar used as a compile-time placeholder).
* The `android_common.stubs.system` variant.
* The `android_common.stubs.module_lib` variant.

For an APEX-bound library, you can end up with on the order of ten or twenty variants of the same source library. Each is built differently.

To make this concrete: on a current `aosp_cf_x86_64_phone` build, the single module `libbase` (declared once at `system/libbase/Android.bp`) expands inside Soong into **65 distinct variants**. Listing `out/soong/.intermediates/system/libbase/libbase/` shows them:

```
android_x86_64_silvermont_shared
android_x86_64_silvermont_shared_apex10000
android_x86_64_silvermont_shared_apex10000_p
android_x86_64_silvermont_shared_apex31
android_x86_64_silvermont_shared_apex33
android_x86_64_silvermont_static
android_x86_64_silvermont_static_apex10000
android_x86_64_silvermont_static_cfi_apex10000
android_vendor_x86_64_silvermont_shared
android_vendor_x86_64_silvermont_static
android_vendor_x86_64_silvermont_static_afdo-libbinder
android_ramdisk_x86_64_silvermont_shared
android_ramdisk_x86_64_silvermont_static
android_recovery_x86_64_silvermont_shared
android_recovery_x86_64_silvermont_static_afdo-libbinder
android_recovery_x86_64_silvermont_static_afdo-libbinder_ndk
android_product_x86_64_silvermont_shared
android_product_x86_64_silvermont_static
android_native_bridge_arm64_armv8-a_shared
android_native_bridge_arm_armv7-a-neon_shared
...   (45 more)
```

Read those variant names like a multi-axis address: `<image>_<arch>_<cpu>_<linkage>[_apex<level>][_afdo-<dep>][_cfi]`. Each axis is one decision the mutator pipeline made. Sixty-five variants for one source library is normal. Multiply this by the ~10,000 `cc_library` modules in AOSP and you get a sense of how the post-mutator graph has hundreds of thousands of nodes.

You write one declaration:

```bp
java_library {
    name: "framework-foo",
    ...
}
```

And Soong's machinery turns it into many module instances internally. Each instance has the same **name** but a different **variant identifier**. A reference to `framework-foo` somewhere else in the build resolves to a *specific* variant based on context (the consumer's variant, the selected SDK level, the apex membership, etc.).

This explains why "small" `.bp` files can blow up internally. A real `Android.bp` may declare ~30 java_library modules. After Soong applies its mutators (next chapter), those 30 modules can become hundreds of variants. The framework alone reaches into the tens of thousands of variants.

Variants are *created* by mutators, where we go next.

## 20. Mutators — the assembly line

Once Soong has parsed all the `Android.bp` files, it has a flat list of module declarations. Each is a typed Go struct. None of them has any variants yet; none of them has resolved its dependencies; none of them has expanded its `defaults` references.

The next phase is the **mutator pipeline**. Mutators are functions written in Go that run over the module set and transform it. Soong has on the order of seventy mutators, registered in a fixed order. They run in two passes: top-down (from roots downward) and bottom-up (from leaves upward).

A mutator can do many things:

* Split a module into multiple variants (the `arch` mutator, the `os` mutator, the `apex` mutator).
* Add or replace dependencies (the `prebuilt_select` mutator that chooses whether a prebuilt or source version of a module is used).
* Merge properties from defaults modules (the `defaults` mutator).
* Create entirely new modules at runtime (the `java_sdk_library` handler creates stubs modules; the `filesystem_creator` creates the device-image module).
* Set internal flags on modules.

A few concrete examples:

**The arch mutator** looks at every module declaring multi-arch support. For an arm64 + arm32 device, it splits `cc_library_shared { name: "libfoo" }` into:
* `libfoo` (arm64 variant)
* `libfoo` (arm variant)
* `libfoo` (host variant, if applicable)

For consumers, the arch mutator also splits *them* into matching variants, so that an arm64 binary depends on the arm64 variant of `libfoo`, not the arm one.

**The defaults mutator** looks at every module with a `defaults` property. For each entry, it finds the referenced `*_defaults` module and merges its properties into the consumer's properties. This is how `framework-module-defaults` gets inlined into every `java_library` that references it.

**The prebuilt_select mutator.** Many libraries in Android exist both as source (the canonical version, compiled from source) and prebuilt (a binary blob shipped with the tree, used when you can't compile from source). For each such pair, `prebuilt_select` decides which is in effect based on flags.

**The apex mutator.** APEX is a packaging format for shipping platform modules independently. A module that's "inside" an APEX is built differently (linked against an APEX-internal SDK, separated from system_server, etc.). The apex mutator figures out which APEXes each module is part of, then creates per-APEX variants where needed.

**The sanitize mutator.** AddressSanitizer and friends. Creates a sanitizer-enabled variant of cc modules if any consumer requests one.

There are dozens more. The fact that there are dozens is one of the deep structural facts about Soong: the rules are not in a constrained DSL like Starlark; they are in **arbitrary Go**. Each mutator is a hundred or a thousand lines of Go that does its own logic, and the Soong runtime calls them in order.

Two crucial structural properties of mutators:

1. **They are whole-graph passes.** A mutator looks at every module. It can read any module's properties or other mutators' decisions. It is NOT a per-module pure function. The arch mutator splitting `libfoo` into arm64 and arm variants will *also* split every consumer of `libfoo` into matching variants, because otherwise the dep edge wouldn't make sense.
2. **They mutate the graph itself.** A mutator can split modules, create new ones, rename, remove. After mutator N runs, the graph is structurally different from what mutator N-1 saw.

These two properties together are why Soong incremental analysis is fundamentally hard. We will return to this repeatedly. When you edit one `.bp` file, you cannot in general know what mutators would do differently without re-running them. And because mutators look at the whole graph, re-running them is not a small per-module operation.

(This is the structural reason Bazel's discipline of restricted rules in Starlark is so important: Bazel rules are pure functions; no analog of mutators exists; the whole analysis is a pure query graph. Bazel gives up Soong's expressiveness for that.)

## 21. Providers — how modules talk

After all mutators have finished, the module graph is fully resolved. Each module knows its variants, its dependencies, its merged properties. The next phase is generating **build actions** — the actual ninja edges that will be emitted.

Each module's `GenerateBuildActions` function runs (in parallel where dependencies allow). But modules need information from each other. If `framework-foo` statically links against `framework-base`, foo's javac command line needs the path to base's compiled `.jar`. How does foo know that path?

The mechanism is **providers**. A provider is a typed message a module exposes to its dependents. It is a Go struct, registered with a Go type identifier. A producer *sets* a provider during its `GenerateBuildActions`; a consumer *reads* a provider during its `GenerateBuildActions` (which runs later, since consumers depend on producers).

Concrete examples:

* **JavaInfo** — describes a `java_library`'s outputs. Fields include `ImplementationAndResourcesJar`, `HeaderJar`, `AidlIncludeDirs`, `SourceJar`, `ExportedFlags`. Set by `java_library`; read by any consumer needing to know where the jar lives.
* **CcInfo** — equivalent for cc modules. Includes export include dirs, exported flags, link order.
* **ApexInfo** — which APEX(es) a module is part of.
* **LicenseInfo** — license metadata.
* **SourceFilesProvider** — the resolved list of source paths a filegroup exposes; consumers inline this in their own srcs.

Providers are how cross-module information flows beyond the simple "A depends on B" edge. They are typed and discoverable: any consumer asking "do you have a JavaInfo?" knows the shape of the answer.

For incremental analysis, providers matter because they are the *width* of cross-module data flow. If a module's exported providers change, its dependents may need to regenerate. If they don't, the dependents can stay cached. This is the basis for what we'll call the "interface-changed" propagation in Soong's incremental path.

## 22. GenerateBuildActions — the ninja faucet

Here is where ninja text actually comes out. After mutators run, each module's `GenerateBuildActions` is called. This method is written by the implementer of each module type, in arbitrary Go.

Let's walk through what a `java_library`'s `GenerateBuildActions` does. The listing below is **stylized**, not a copy-paste from Soong: in real Soong this lives in `build/soong/java/library.go` and the provider key is called `JavaInfoProvider` (a `blueprint.ProviderKey[JavaInfo]`), not `JavaInfoKey`. I've shortened identifiers, dropped error handling, and inlined a few helpers to keep the shape readable. If you `grep` for `JavaInfoKey` in the real tree, you will not find it; what you want is `JavaInfoProvider`. The structural shape is faithful to the real code, but every name and call site has been simplified.

```go
func (j *JavaLibrary) GenerateBuildActions(ctx ModuleContext) {
    // 1. EXPAND SRCS.
    srcs := []android.Path{}
    for _, s := range j.properties.Srcs {
        if strings.HasPrefix(s, ":") {
            // module reference; read SourceFilesProvider from the dep
            dep := ctx.GetDirectDepWithTag(s[1:], ...)
            info := ctx.OtherModuleProvider(dep, SourceFilesProviderKey)
            srcs = append(srcs, info.Files...)
        } else if strings.Contains(s, "*") {
            srcs = append(srcs, ctx.Glob(s)...)
        } else {
            srcs = append(srcs, android.PathForModuleSrc(ctx, s))
        }
    }

    // 2. COMPUTE CLASSPATH.
    classpath := []android.Path{}
    ctx.VisitDirectDepsWithTag(staticLibTag, func(dep Module) {
        depInfo := ctx.OtherModuleProvider(dep, JavaInfoKey).(JavaInfo)
        classpath = append(classpath, depInfo.HeaderJar)
    })

    // 3. EMIT JAVAC EDGE.
    jar := android.PathForModuleOut(ctx, "javac", j.Name()+".jar")
    ctx.Build(pctx, android.BuildParams{
        Rule:    javacRule,
        Inputs:  srcs,
        Output:  jar,
        Args: map[string]string{
            "classpath": strings.Join(classpath, ":"),
            "sources":   strings.Join(srcs, " "),
        },
    })

    // 4. EMIT D8 EDGE.
    dexJar := android.PathForModuleOut(ctx, "d8", j.Name()+".dex.jar")
    ctx.Build(pctx, android.BuildParams{
        Rule:   d8Rule,
        Input:  jar,
        Output: dexJar,
    })

    // 5. EMIT HEADER JAR.
    headerJar := android.PathForModuleOut(ctx, "header", j.Name()+".header.jar")
    ctx.Build(pctx, android.BuildParams{
        Rule:   headerJarRule,
        Input:  jar,
        Output: headerJar,
    })

    // 6. SET PROVIDER.
    android.SetProvider(ctx, JavaInfoKey, JavaInfo{
        ImplementationAndResourcesJar: jar,
        HeaderJar:                     headerJar,
        DexJar:                        dexJar,
        AidlIncludeDirs:               j.properties.AidlIncludeDirs,
    })
}
```

That `ctx.Build(...)` call is where ninja text gets generated. Each call appends one build edge to the module's in-memory buffer. After all modules run, those buffers get flushed to the shard files on disk.

For one `java_library`, `GenerateBuildActions` might emit ~50 lines of ninja text, with several rule references and intermediate edges. Multiplied across thousands of java_library variants, the ninja text totals hundreds of megabytes.

Let's stop being abstract and look at *real* ninja text. Below is a verbatim slice of what Soong emits today for `libbase`'s `android_x86_64_silvermont_shared` variant, pulled out of `build.aosp_cf_x86_64_phone.incremental.ninja`. I've trimmed long arg lists for readability but the structure is exactly what Ninja consumes:

```ninja
build $
        out/soong/.intermediates/system/libbase/libbase/android_x86_64_silvermont_static/obj/system/libbase/chrono_utils.o: $
        g.cc.cc system/libbase/chrono_utils.cpp | ${ccCmd}
    description = ${m.libbase_android_x86_64_silvermont_static.moduleDesc}clang++ chrono_utils.cpp${m.libbase_android_x86_64_silvermont_static.moduleDescSuffix}
    tags = module_name=libbase;module_type=cc_library;rule_name=cc
    cFlags = ${m.libbase_android_x86_64_silvermont_static.cFlags1}

build $
        out/soong/.intermediates/system/libbase/libbase/android_x86_64_silvermont_shared/unstripped/libbase.so: $
        g.cc.ld $
        out/soong/.intermediates/system/libbase/libbase/android_x86_64_silvermont_static/obj/system/libbase/chrono_utils.o $
        out/soong/.intermediates/system/libbase/libbase/android_x86_64_silvermont_static/obj/system/libbase/cmsg.o $
        ...

build $
        out/soong/.intermediates/system/libbase/libbase/android_x86_64_silvermont_shared/before_final_validations/libbase.so: $
        g.cc.strip $
        out/soong/.intermediates/system/libbase/libbase/android_x86_64_silvermont_shared/unstripped/libbase.so $
        | ${g.cc.stripPath} ${g.cc.xzCmd} ${g.cc.createMiniDebugInfo}
    description = ${m.libbase_android_x86_64_silvermont_shared.moduleDesc}strip libbase.so${m.libbase_android_x86_64_silvermont_shared.moduleDescSuffix}

build $
        out/soong/.intermediates/system/libbase/libbase/android_x86_64_silvermont_shared/libbase.so: $
        g.android.Cp $
        out/soong/.intermediates/system/libbase/libbase/android_x86_64_silvermont_shared/before_final_validations/libbase.so
    description = ${m.libbase_android_x86_64_silvermont_shared.moduleDesc}copy libbase.so${m.libbase_android_x86_64_silvermont_shared.moduleDescSuffix}
    tags = module_name=libbase;module_type=cc_library;rule_name=Cp

build out/target/product/vsoc_x86_64/system/lib64/libbase.so: $
        g.android.CpWithBash $
        out/soong/.intermediates/system/libbase/libbase/android_x86_64_silvermont_shared/libbase.so $
        || dedup-9dd98d4c58ffffd7
    description = ${m.libbase_android_x86_64_silvermont_shared.moduleDesc}install libbase.so${m.libbase_android_x86_64_silvermont_shared.moduleDescSuffix}
```

Read it from top to bottom and you can see the entire pipeline of what it takes to ship one `.so` to the device. **First**, every `.cpp` file becomes a `.o` via the `g.cc.cc` rule (the `g.cc.` prefix is the namespace; `g.` is Blueprint's global-variable prefix). Each compile gets a `cFlags` per-edge variable pointing at a module-level shared cflags blob (the `${m.libbase_...cFlags1}` reference) — a small optimization that keeps the manifest from repeating the same long flag list a hundred times. **Second**, all the `.o` files for the *static* variant of `libbase` get linked into `unstripped/libbase.so` via `g.cc.ld`. Interesting wrinkle: the shared variant's link edge actually consumes the *static* variant's `.o` files. They share object code; Soong models them as separate variants but the underlying compilation is reused. **Third**, the unstripped `.so` is stripped of debug info into `before_final_validations/libbase.so`. **Fourth**, a copy (essentially a rename + atomicity boundary) produces the canonical `libbase.so` artifact. **Fifth**, an install-side copy lands the `.so` at `out/target/product/vsoc_x86_64/system/lib64/libbase.so` — the actual path it will end up at on the device's `/system/lib64`. The trailing `|| dedup-9dd98d4c58ffffd7` is the order-only-dep-dedup machinery from Fix 2 in chapter 51: many install edges share the same set of order-only inputs (timestamps, license stamps), and Soong replaces the shared list with a phony aggregator named after a content hash.

Every line of this ninja was emitted by `cc_library_shared`'s `GenerateBuildActions` in `build/soong/cc/library.go`. For *one* variant of *one* module. With 65 variants of `libbase` alone, this same pipeline emits ~325 build edges just for that one library. Across the tree, the count is in the millions. That is why `incremental.ninja` is ~2.9 GB before sharding.

For incremental analysis, `GenerateBuildActions` is where most of the visible build "behavior" comes out. If we want to skip work incrementally, we want to skip calling `GenerateBuildActions` on modules whose inputs haven't changed.

This is what Soong's per-module cache (the `buildActionsCache`) tries to do, currently behind the flag `--incremental-build-actions`. It hashes each module's resolved inputs (properties + dependency provider hashes), looks up the hash in the cache, and if it's a hit, reuses the cached ninja text without calling `GenerateBuildActions` at all. We'll return to this in Part X.

## 23. Singletons — the whole-graph aggregators

After every module's `GenerateBuildActions` has run, the modules' build actions are all in memory inside Soong's `Context`. But the build isn't done, because some build outputs are derived from the *whole* module set, not from any single module. These are **singletons**.

A singleton is like a module that runs *once*, after all modules, and walks the whole module set to do something. Examples:

* **module-info.** Produces `module-info.json`: a giant JSON describing every module in the build (name, class, installed locations, dependencies). The shell helper `m foo` uses this file to know which targets to invoke when you type `foo`.
* **all-modules.** Emits a "build everything" ninja phony target that depends on every installed file.
* **raw-files.** Aggregates "raw file" entries that several modules contribute.
* **license-graph.** Walks every module's license metadata, computes the transitive license closure, emits one license-graph file.
* **packaging.** Generates the ninja edges for "make `system.img`" by walking every installable module to figure out what goes where.
* **vts-suite, cts-suite, etc.** Test suite assembly: walk every test declared in the tree, collect its files, emit packaging.

Singletons **fold** over the module set. Their output depends on every module's contribution.

In Soong's design, singletons are **single-use**. Their `GenerateBuildActions` runs once. Trying to call it again on the same Soong process either crashes (double-setting providers), silently no-ops (internal `sync.Once` guards already tripped), or produces empty / wrong output (state was consumed).

This single-use property is **the** deepest reason incremental analysis is hard. Adding or removing a module changes every singleton's output. The naive way to handle that is to re-run the singletons. We can't. The clean way is to express each singleton as an *incremental fold* over recorded per-module contributions. We haven't done that yet, broadly.

We will spend Part VIII deep in this problem.

## 24. Manifest assembly

After everything has run, Soong serializes the build actions into a ninja manifest. The manifest has:

* One top-level `build.aosp_<product>.ninja` file. Tiny, just `subninja` lines pointing at the shards.
* The shard files (`build.aosp_<product>.NNN.ninja`), one per `SOONG_NINJA_SHARDS` bucket. Each contains the build statements for a hash-bucketed subset of modules. Sizes vary depending on which modules hash into the bucket.
* A `singletons` subninja for the singletons' output. ~112 MB on a current tree.
* A `phonys` subninja for any "dedup" phony aggregations.
* An `incremental` subninja for incrementally-supported module actions. ~2.9 GB before sharding — the single biggest piece of the manifest.

Combined: ~5.6 GB of text on a current `aosp_cf_x86_64_phone-trunk_staging-userdebug` build. Writing it all takes ~37 seconds on a fast workstation; cold-reading it in Ninja takes ~5 seconds. Re-measure before you quote anything — the totals vary with the tree and the shard count.

## 25. The spine: what `m frameworks/base` really does, step by step

We have enough vocabulary to walk through the whole flow. You type:

```sh
m frameworks/base
```

Here is everything that happens, in order. This is the spine of the document.

**Step 1: soong_ui starts** (~1 second, cold or warm).

`soong_ui` is the outer driver, a Go program at `build/soong/cmd/soong_ui`. It sets up environment variables, locks the output directory (so two builds don't race), and orchestrates everything that follows.

**Step 2: Product configuration via Kati** (~2.5 seconds).

Soong needs to know what you're building for. There are hundreds of product configurations in AOSP (`aosp_cf_x86_64_phone`, `gphone64_arm64`, automotive, —). Each is described by a constellation of `.mk` files: `PRODUCT_NAME`, `BOARD_VARIANT`, `TARGET_ARCH`, etc.

`soong_ui` invokes Kati on the product config Makefiles. Kati parses them, evaluates them, and emits the final "variables" file (`soong.variables`, `dumpvars-Make.mk`, etc.). This includes everything from "which architecture are we building for" to "which release flags are turned on."

**Step 3: Kati packaging pass** (~1-2 seconds).

A small Kati pass produces a packaging-only ninja file. This handles some legacy install rules and other glue.

**Step 4: Globs and bootstrap** (~2-3 seconds).

`soong_ui` regenerates a small `bootstrap.ninja` file that tells the build how to find Soong itself, and runs glob-validity checks (does the file set match what Soong recorded last time? if not, re-run Soong).

**Step 5: Soong analysis** (cold: ~131s total; warm: see Part VIII).

Now the main event. `soong_ui` invokes the `soong_build` binary, which does:

* **5a: Parse `.bp` files.** Soong walks the tree of `Android.bp` files (~14,000) in parallel. Each is parsed into a list of `Module` declarations. Soong registers them into its in-memory `Context`. Cold: ~5s.
* **5b: Resolve dependencies and run mutators.** For each module, link up its dep references (`static_libs: ["framework-base"]` becomes "this is module `framework-base`"), then run the ~70 mutators (top-down then bottom-up) in registered order. Each may split modules into variants, create new modules, modify deps, expand defaults. By the end, the graph has tens of thousands of variants where there were thousands of declarations. Cold: ~34s (the `resolve_deps` phase, which includes the mutator pipeline).
* **5c: Prepare build actions.** Each module's `GenerateBuildActions` runs (in parallel where deps allow). Each emits ninja text into one of the shard buffers. Providers are set. Then each singleton's `GenerateBuildActions` runs (single-use, in a fixed order). Cold: ~51s (the `prepare_build_actions` phase: ~31s in `generateModuleBuildActions`, ~18s in `generateSingletonBuildActions`, of which the phony singleton alone is ~9.4s) — the largest phase.
* **5d: Write the manifest.** All in-memory buffers are flushed to disk: the shards plus a handful of special files. Total ~5.6 GB. Cold: ~37s.

**Step 6: Ninja execution.** Cold full build: tens of minutes to hours. Warm: seconds.

Ninja reads the manifest, builds the DAG in memory, schedules the dirty edges, and runs actual compilers/linkers/packagers in parallel.

That's the spine. If you understand this sequence, you understand what a build is, in operational terms.

For incremental analysis, the parts that matter most are Step 5 (analysis) and Step 6 (execution). Step 6 has its own incrementality machinery built into Ninja: it doesn't re-run commands whose inputs haven't changed. The remaining problem is making Step 5 incremental.

Most of this document is about Step 5.

---

# Part VI — Where the time goes

A cold full AOSP build takes hours. A warm incremental build, in principle, should take seconds. The gap is where the engineering opportunity lives. Let's break it down.

## 26. Cold-build cost breakdown

Here are rough numbers for a cold full build of `aosp_cf_x86_64_phone`. Your numbers will vary substantially with machine, target, and AOSP revision; the *shape* of the breakdown is what's stable, not the absolute values.

**Provenance for the numbers in this table.** I measured these on my own workstation, on branch `dev/zezeozue/incr-redesign` at commits `a4ae722` (build/blueprint) + `ba9c1c423` (build/soong), with `aosp_cf_x86_64_phone` as the lunch target. Hardware: 32-core AMD workstation, 256GB RAM, NVMe SSD, Ubuntu 22.04 LTS, kernel 6.8. The cold-build numbers are the median of three runs starting from a fully clean `out/` directory. Where ranges appear ("~3-4s"), they reflect run-to-run variance rather than uncertainty about the median. Re-measure on your own setup before quoting these as authoritative; AOSP build times can swing 2x for the same target across different machines, and they drift over time as the tree grows. If your numbers are wildly different from mine — say, more than 2x in either direction — assume your environment is different (slower disk, missing RAM, hot CCACHE you didn't expect, kernel build artifacts in a wrong state) rather than that the table is wrong.

| Phase | Cold time | What's happening |
|---|---|---|
| soong_ui start | ~1s | Outer driver setup, lock acquisition |
| Kati dumpvars | ~2.5s | Read product config `.mk` files |
| Kati packaging | ~1-2s | Legacy Make logic |
| Bootstrap / globs | ~2-3s | Regenerate bootstrap.ninja, check globs |
| Soong: parse .bp | ~5s | Read ~14,000 `Android.bp` files |
| Soong: resolve deps + mutators | ~34s | Link `static_libs:` references, run ~70 mutators, create variants |
| Soong: GenerateBuildActions (modules) | ~31s | Per-module ninja emit |
| Soong: singletons | ~18s | Whole-graph aggregations (phony singleton alone ~9.4s) |
| Soong: write manifest | ~37s | Flush the shards (~5.6 GB) |
| Ninja: parse | ~5s | Read ~5.6 GB of ninja |
| Ninja: scan dirty | ~5s | Check mtimes |
| Ninja: execute | ~minutes — hours | Actual compile/link/dex/aapt2/etc. |

The execute phase is where the time goes on a cold build, but the analysis phase (Soong + Ninja parse) is the floor that even *no-op* warm builds can never escape. Cutting analysis to milliseconds is what changes the inner loop.

### Inside the execute phase

The "execute phase" above is a black box that hides where most of cold-build time actually goes. For a complete `m droid` cold build of `aosp_cf_x86_64_phone`, the dominant pieces inside Ninja execution are:

| Inside Ninja: phase | Cold time | What's running |
|---|---|---|
| javac | ~5-15 min | Framework + module Java compiles |
| Turbine (header jars) | ~1-3 min | API-surface jars for compile avoidance |
| d8 (dexing) | ~2-5 min | Java bytecode — DEX |
| aapt2 (resources) | ~30s—2 min | Drawables, layouts, strings — binary |
| metalava (all stubs) | ~5-10 min | 298 invocations, multi-SDK stubs |
| R8 (release builds only) | ~1-3 min | Tree-shaking, optimization, obfuscation |
| APEX assembly | ~5-10 min | Dozens of APEXes, signed, packaged |
| dex2oat (dexpreopt) | ~10-20 min | Ahead-of-time compile for boot image |
| Native compile (clang) | ~10-30 min | C/C++/Rust across thousands of variants |
| Native link (lld) | ~2-5 min | Linking shared libraries and binaries |
| All other (zip, copy, sign, gen, etc.) | ~5-15 min | The long tail |

The exact ordering depends on the DAG and which CPUs are free. The point is that "execute" is not one cost — it's a dozen costs, each with their own internal incrementality story (or lack of one). Native compile is the largest single chunk on a cold full build; metalava and dex2oat together can equal it on a build that hits a lot of framework-Java surface. Inner-loop edits typically rerun only a tiny fraction of these (a Java change rebuilds a few javac invocations, maybe one metalava, no dexpreopt), but on a cold build the bill is real.

## 27. Why startup is slow

"Startup" usually means everything before Ninja starts running actual compile commands. For AOSP that's roughly 2-4 minutes cold, 15-30 seconds warm.

The cold case is dominated by Soong's parse + mutators + GenerateBuildActions + manifest write. Each is a tree-walk: every `Android.bp` file is read, every module is mutated, every module emits ninja text, every shard is written.

The warm case is dominated by:

* **soong_ui floor**: ~7-8s of outer work (dumpvars ~2.5s, packaging, glob check, bootstrap, orchestration). Mostly Kati. None of this should need to re-run if no relevant `.mk` files changed, but it does because nothing has wired up caching here.
* **Soong reparse**: ~0.4s. With the resident daemon, a warm Soong reparses only the `.bp` files whose content hash changed (12 of 14,003 on a real frameworks/base edit); the parsed graph for the rest of the tree is reused.
* **Soong incremental analysis**: ms-to-seconds for the changed module(s) and their interface-propagation closure; soong analysis total ~4.4s, byte-identical to cold.
* **Ninja parse**: ~5.1s. Stock ninja keeps no state between runs, so it re-reads the whole ~5.6 GB manifest every build. A resident ninja (n2) could avoid this, but it is not engaged in the current path.

The breakdown matters because the path to ms overhead is closing *each* of these floors. No single fix gets you to sub-second; you need to close every one.

### What each floor is actually doing

The phase labels above are abstract. Let's open them up.

**Kati dumpvars (~2.5s).** Soong needs to know what device you're building for, and that information lives in Make-format product config files. `soong_ui` invokes Kati on a tree of `.mk` files starting at `build/make/core/config.mk`, which recursively includes `build/make/target/product/aosp_cf_x86_64_phone.mk`, which includes `device/google/cuttlefish/vsoc_x86_64/aosp_cf.mk`, which includes another half-dozen device-specific `.mk` files. By the time Kati has evaluated them all, hundreds of Make variables — `TARGET_PRODUCT`, `TARGET_ARCH`, `BOARD_VENDOR`, `PRODUCT_PACKAGES`, the whole world — have been resolved. Kati writes the resolved values to `out/soong/soong.variables` (a JSON file Soong reads) and exits. The work is real and complicated; the part that's pure waste in the inner loop is that no `.mk` file's content hash is checked first, so it runs every build even when nothing changed.

**Kati packaging (~1-2s).** A second Kati pass evaluates the parts of the build that haven't migrated to Soong yet — mostly `system.img` packaging glue and some legacy install rules. It produces a smaller ninja file (`out/soong/build.aosp_cf_x86_64_phone.kati.ninja`) that gets glued into the top-level. Same waste pattern: re-runs every time.

**Bootstrap.ninja regen (~2-3s).** `soong_ui` regenerates a small ninja file (`out/soong/bootstrap.ninja.in`) that knows how to build `soong_build` itself from its Go sources. It's about 30 lines of ninja. The actual file rarely changes. The regen exists because the Soong source under `build/soong/**/*.go` could in principle have been edited since last build, and if it was, `soong_build` itself needs to be rebuilt. The cost is mostly stat'ing every `.go` file under `build/soong/` plus the entire `build/blueprint/` tree to be sure none was touched. Worth caching by a hash of those source trees.

**Glob check (~1s).** Soong sometimes uses globs in srcs (e.g., `"src/main/java/**/*.java"`). For these to be reliable across builds, the build system needs to detect when a new file is added that would now match an existing glob. Currently, every build walks the relevant directories and checks the file set against a recorded baseline. Inotify would tell us when a directory's contents change; that signal isn't currently wired in.

Past these four pieces, the rest of the warm time divides into *real analysis work* (Soong reparse, mutator re-derive, manifest delta-write) and the stock-ninja manifest reload. The analysis work is O(edit). The pre-analysis overhead (the four pieces above) and the ninja reload are the floors that remain. Closing the soong_ui pieces is in chapter 60; the ninja reload is chapter 33.

## 28. Why a `.bp` edit costs more than it should

Even with the warm path engaged (the corpus passes byte-identical for comment/reorder/dropsrc edits, and for real property edits to existing modules), the total wall time is ~17.8 seconds. Let's break that down.

| Cost | Time | Why |
|---|---|---|
| soong_ui orchestration + bootstrap | ~5s | bootstrap, glob check, orchestration |
| dumpvars / product config | ~2.5s | ckati re-runs over the product `.mk` files every build; no config-hash cache |
| Changed-file reparse | ~0.4s | Only the `.bp` files whose hash changed are reparsed |
| Mutator re-derivation | ~ms | Only on the changed module closure |
| Per-module action regen | ~ms | Module + interface-propagated dependents |
| Shard delta write | ~3.6-4s | Rewrite only the shards holding a changed module |
| Ninja manifest reload | ~5.1s | Stock ninja re-parses the whole 5.6 GB manifest (no resident state) |
| Ninja scan + execute | <1s | Nothing actually rebuilt for a comment-only edit |

The soong analysis itself — reparse + re-mutate + regen + delta write — totals ~4.4s and is byte-identical to a cold rebuild. The wall time that is *not* analysis is the dumpvars run (recomputed every build) and the ninja manifest reload (stock ninja keeps nothing in memory). Those two are the remaining floors; each is in principle eliminable, and each is several days of focused work.

### Annotated trace of a warm `.bp` edit

Here is what happens, with timing, on a one-property edit to
`frameworks/base/services/core/Android.bp` (the `services.core.unboosted`
library) with the resident daemon running and `SOONG_NINJA_SHARDS=50`. The edit
touches 8 module variants. The regenerated `build.ninja` is byte-identical to a
cold rebuild of the same edited tree (`cmp`, 403/403 manifest shards).

```
soong_ui starts and connects to the resident soong_build daemon over a unix
  socket. The daemon holds the resolved+mutated graph in RAM, so the ~131 s of
  cold parse + resolve + mutate is not paid.

dumpvars (product config): ~2.5 s. soong_ui re-runs ckati over the product .mk
  files on every build; there is no config-hash cache, so this is paid even
  though the config did not change.

soong analysis, in the daemon:
  reparse        0.40 s   only the .bp files whose content hash changed are
                          reparsed (12 of 14,003: the edited file plus
                          module-less files); the parsed graph for the other
                          ~14k files is reused.
  re-mutate      ~ms      only the changed module closure re-runs the mutators.
  regenerate     ~ms      only dirty modules, plus dependents whose exported
                          provider interface changed, re-emit ninja.
  delta write    ~3.6 s   only the shards containing a changed module are
                          rewritten (3 of 50 module shards; the multi-GB
                          incremental-modules subninja is sharded the same way);
                          the rest are left on disk untouched.
  total          ~4.4 s   byte-identical to a cold rebuild.
                          (v0.8: now ~0.76s add / ~0.80s remove / ~1.64s edit --
                          the dedup, singleton and sort/shard recomputes that
                          dominated this number are now O(edit) caches; see ch. 58.)

ninja: ~5.1 s. Stock ninja keeps no state between runs, so it re-parses the
  whole 5.6 GB manifest into RAM, finds nothing to do, and exits.

TOTAL: ~17.8 s wall, of which:
  ~4.4 s   soong analysis (the ninja generation)  -- O(edit), byte-identical
  ~2.5 s   dumpvars / product config              -- recomputed every build
  ~5.1 s   ninja reloading the 5.6 GB manifest     -- stock ninja, no resident state
  ~5   s   soong_ui orchestration + bootstrap
```

The soong analysis -- the work that produces the updated `build.ninja` -- is
O(edit): it scales with what changed, not with the 14k-file tree, it is
single-digit seconds (~30x below the cold 131 s), and it is byte-identical to
cold. The rest of the wall is not analysis. It is product config that is
recomputed every build, and a ninja process that reloads the entire manifest
because it keeps nothing in memory between runs. Those two are the remaining
floors (chapters 31-33, 60).

The cost is O(edit) only for the analysis. The full wall still carries the
product-config and ninja-reload floors. Adding and removing a module are now warm
too (and byte-identical to a cold resident rebuild), but they are a *membership
change*: the whole-graph singletons re-aggregate over the new module set, so an
add used to be dominated by singleton regeneration rather than being the
few-seconds a property edit is. A **singleton contribution probe** now skips the
singletons the added module doesn't surface — on the f/b `cc_defaults` add, 65 of
66 skip (`testsuites`, `soongonlyandroidmk`, `all_teams`, … only `bootstrap`
re-runs), bringing regen+write from **17.2 s to 9.8 s**, still byte-identical
(467/467 shards). The probe runs each singleton over the changed modules vs the
empty set in a side-effect-free throwaway context and keeps its resident output
when the two match; the changed-set is keyed by a tolerant provider-value hash so
a re-parse-hash false positive drops out. The remaining 9.8 s is the probe
overhead (~4.3 s, serialised by soong's per-config `Once` lock) and the O(tree)
manifest write (~5.3 s) — the two next levers (see the SUMMARY's "Why sub-second
is NOT yet reached").

## 29. The soong_ui floor

The outer driver runs Kati (dumpvars + packaging), regenerates `bootstrap.ninja`, and runs glob checks, *every* build invocation. Together this is ~7-8 seconds, of which the dumpvars run alone is ~2.5s.

The fixes:

* **Cache dumpvars output.** Hash the set of relevant `.mk` files. If the hash matches the previous build, skip the dumpvars invocation and reuse the cached `soong.variables`. Saves ~2.5s.
* **Skip Kati packaging when nothing relevant has changed.** Same idea, applied to the packaging-pass output. Saves ~1-2s.
* **Cache bootstrap.ninja regeneration.** Soong's own source rarely changes during inner-loop work. If `build/soong/**` hashes match the previous build, skip regenerating `bootstrap.ninja`. Saves ~2-3s.
* **Defer glob checks until something looks suspicious.** Currently glob checks run unconditionally to catch "did anyone add a new source file matching an existing glob?" Could use inotify or filesystem timestamps to detect when this is necessary. Saves ~1s.

Sum: cutting the soong_ui floor from ~7s to <1s is straightforward but real engineering. The Kati dumpvars caching alone is the highest-leverage piece because it's the single largest contributor.

## 30. The Kati floor

Kati exists because some Make logic hasn't moved to Soong. The long-term fix is moving more Make logic into Soong (product config in particular). The medium-term fix is caching Kati's output as described above. The short-term fix is making Kati itself faster, which Google has invested in.

Within an inner-loop edit, Kati's correct contribution is essentially nothing. It should be a cache hit every time. Making that cache hit reality is the work.

## 31. The Soong analysis floor

With the resident daemon the warm analysis breaks down as:

* **Reparse: ~0.4 s.** Only the `.bp` files whose on-disk content hash differs
  from the daemon's snapshot are reparsed; the parsed graph for the rest of the
  ~14k files is reused (chapter 59). A diff over just the reparsed files yields
  the dirty module set.
* **Mutator re-derive: ~ms.** Only the changed module closure re-runs the
  mutators; the rest of the graph is untouched.
* **Per-module regeneration + propagation: ~ms.** Only dirty modules, plus
  dependents whose exported provider interface actually changed, re-emit.
* **Shard delta write: a few seconds.** Only the manifest shards containing a
  changed module are rewritten. The multi-GB incremental-modules subninja is
  sharded the same way, so a one-module edit rewrites one small shard rather than
  the whole file.

The analysis itself is O(edit) and byte-identical to cold. The remaining warm
floors are outside analysis: product config (chapter 60) and the ninja manifest
reload (chapter 33).

## 32. The ninja-write floor

When Soong emits a manifest, the multi-gigabyte write itself takes ~37s cold. Incremental analysis already mitigates this by writing only the shards containing changed modules (~3.6-4s for a typical inner-loop edit, since only the shards holding a changed module — 3 of 50 module shards on a real frameworks/base edit — are rewritten; the multi-GB incremental-modules subninja is sharded the same way, so the rest is left on disk untouched).

Further work could push this lower. The shards are independent text files; in principle one could keep the shard contents in shared memory across builds and just patch the affected ranges. The savings (a few hundred ms) aren't huge but they're real for the sub-second goal.

## 33. The ninja-execute floor

Ninja reads the manifest, builds the DAG, and scans for dirty edges. Stock ninja
keeps nothing between invocations, so on the 5.6 GB AOSP manifest it re-parses
the whole thing into RAM every time -- ~5 s on a warm near-no-op edit, even with
nothing to run. This is the single largest piece of the warm wall.

Eliminating it needs a resident ninja: a long-lived process that keeps the
parsed DAG in memory and, on each build, re-reads only the shards that changed
and patches its in-RAM graph, instead of reloading the whole manifest. n2 (a
Rust ninja reimplementation) can run this way. This is not engaged in the
 measured warm path above; the ~5 s reload is stock ninja.

Verified: the resident-n2 path as it exists does NOT work. The n2 server starts
and tries to load the 5.6 GB manifest into RAM, but the load takes over four
minutes (it times out), so it never reaches the incremental-splice fast path and
falls back to stock ninja. Stock ninja reloads the same manifest in ~4 s -- about
50x faster than n2's load -- so the resident path is currently far worse, not
better. Making it viable is a Rust performance problem in n2's manifest parse and
DAG construction, not a wiring change; it is the biggest single unsolved wall
floor and a genuinely hard one.

# Part VII — The Java pipeline and friends

I've focused so far on the Soong analysis side. But a real `m frameworks/base` build also runs huge amounts of Java work that goes well beyond `javac`. Let's tour the actual Java pipeline. The numbers below are for the framework specifically; smaller modules are proportionally faster.

## 34. javac: still here, still slow

When you compile a framework Java library, Soong emits a `javac` invocation. javac is the canonical Oracle Java compiler. It is mature, correct, and not fast.

For framework-core (~500K lines of Java), a single javac invocation takes around 30-60 seconds on a fast machine. Multiplied across many framework libraries and SDK levels, that's many minutes of build time.

Ways to fix this:

* **Persistent javac daemon.** Instead of forking javac per compile, keep a Java process running with the compiler classes already loaded; send compilation requests to it. JetBrains' Kotlin daemon does this. Avoids JVM startup (~1s) and JIT warmup (several more seconds) per invocation. Buck2 has built-in support for "persistent workers" of this kind.
* **Header jars (a.k.a. Turbine).** Don't link compile-time against the full implementation jar of a dependency; link against a much smaller header jar that exposes only the API surface. Soong already does this with Turbine. The saving is that downstream javacs are smaller.
* **Compile avoidance via ABI hashing.** Only recompile a downstream module if the *ABI* of its upstream changed, not just the implementation. Bazel does this; Gradle does this; Buck2 does this. Soong's interfaceChanged propagation is the analog at the module-graph level, but inside one module's javac compilation it's less elaborate.

There's a fundamental floor: javac is single-threaded per-file, and big libraries take real time. Without something like a hot daemon + ABI-only invalidation, this is a real fraction of the inner loop on Java edits.

## 35. Metalava: the SDK API checker

For framework modules that expose a public API, Soong runs **metalava** after javac to:

* Generate API stubs (the SDK jar consumers compile against).
* Generate API signature files (the canonical `.txt` files describing every public API).
* Check for API compatibility — *did this CL add, remove, or change any public API*.

Metalava is a heavyweight tool. For framework-core, a single metalava run takes 30 to 90 seconds. It is run multiple times per inner loop because there are multiple SDK levels (current, system, module-lib) each with their own stubs.

Metalava is currently a major contributor to "framework edit is slow" complaints. Fixes:

* **Daemon-mode metalava.** Same idea as javac: keep metalava running as a long-lived process, avoid JVM startup, reuse parsed AST. Google has prototyped this; not yet shipped widely.
* **Incremental metalava.** Hash inputs (source files); cache the API output. If your CL doesn't change a public API, metalava should be a cache hit. Currently it isn't, because the implementation is "read all sources, produce all stubs, every time."
* **API-only path.** When only an implementation file changed and no public-API surface changed, metalava could short-circuit. This requires metalava to be able to *tell* that no public API changed cheaply, which is itself a non-trivial analysis.

This is one of the highest-impact warm-Java fixes available. Cutting the metalava cost for inner-loop edits from 30-90s to <1s would change framework iteration dramatically.

### Real numbers from a real metalava invocation

Talking about metalava abstractly is one thing; let's look at what Soong actually invokes. A grep for `metalava.sbox.textproto` in a current AOSP build directory finds **298 separate metalava invocations** scheduled per cold build:

```
$ find out/soong/.intermediates -name 'metalava.sbox.textproto' | wc -l
298
```

That is not "metalava runs once and produces the SDK." It is "for every API surface in Android (each apex's API, each module's stubs, each `current.txt` / `system-current.txt` / `module-lib-current.txt` slice), Soong scheduled an independent metalava invocation." Three hundred separate ~30-second JVM startups.

The command line for a single one is also worth seeing. Below is the actual command Soong builds for the `framework-permission.stubs.source.system` metalava action, lightly reformatted but otherwise verbatim from `metalava.sbox.textproto`:

```bash
out/host/linux-x86/bin/sbox \
  --sandbox-path out/soong/.temp \
  --output-dir <out>/framework-permission.stubs.source.system/android_common/everything \
  --manifest <out>/framework-permission.stubs.source.system/android_common/metalava.sbox.textproto \
  --write-if-changed

# ...inside the sandbox, the actual metalava invocation:
__SBOX_SANDBOX_DIR__/tools/out/bin/metalava \
  -J-XX:OnError="cat hs_err_pid%p.log" \
  -J-XX:CICompilerCount=6 \
  -J-XX:+UseDynamicNumberOfGCThreads \
  -J-XX:+TieredCompilation \
  -J-XX:TieredStopAtLevel=1 \
  -J--add-opens=java.base/java.util=ALL-UNNAMED \
  --java-source 21 \
  @<out>/framework-permission.stubs.source.system/android_common/everything.metalava.rsp \
  @<out>/srcjars/list \
  --classpath <out>/android_module_lib_stubs_current.jar:\
             <out>/core-lambda-stubs-src.jar:\
             <out>/framework-annotations-lib.jar \
  --color --quiet --format=v2 --repeat-errors-max 10 \
  --hide UnresolvedImport \
  --api-class-resolution api \
  --format-defaults overloaded-method-order=source,add-additional-overrides=yes \
  --config-file build/soong/java/metalava/main-config.xml \
  --config-file build/soong/java/metalava/source-model-selection-config.xml \
  --api-surface system \
  --hide-annotation android.annotation.Hide \
  --api <out>/framework-permission.stubs.source.system_api.txt \
  --removed-api <out>/framework-permission.stubs.source.system_removed.txt \
  --stubs <out>/framework-permission.stubs.source.system/android_common/everything/stubsDir \
  --exclude-documentation-from-stubs \
  --include-annotations \
  --exclude-annotation androidx.annotation.RequiresApi \
  --migrate-nullness <out>/framework-permission.api.public.latest \
  --migrate-nullness <out>/framework-permission.api.system.latest \
  --extract-annotations <out>/framework-permission.stubs.source.system_annotations.zip \
  --check-compatibility:api:released <out>/framework-permission.api.public.latest \
  --check-compatibility:api:released <out>/framework-permission.api.system.latest \
  --check-compatibility:removed:released <out>/framework-permission-removed.api.public.latest \
  --check-compatibility:removed:released <out>/framework-permission-removed.api.system.latest \
  --baseline:compatibility:released <out>/framework-permission-incompatibilities.api.system.latest \
  --error UnhiddenSystemApi --error UnflaggedApi \
  --error-when-new FlaggedApiLiteral \
  --show-annotation 'android.annotation.SystemApi(client=android.annotation.SystemApi.Client.PRIVILEGED_APPS)' \
  --api-lint \
  --api-lint-previous-api <out>/framework-permission.api.public.latest \
  --api-lint-previous-api <out>/framework-permission.api.system.latest \
  ...
```

I have trimmed about a dozen more flags for length; the real command line is 33 distinct `--flag` arguments long, and that is just one of the 298 invocations.

What is going on inside one of those metalava runs, mechanically:

1. **JVM startup**: ~1-2 seconds before any user code runs. The flags `-J-XX:CICompilerCount=6 -J-XX:TieredStopAtLevel=1` are Soong tuning the JVM down (fewer JIT compiler threads, no high-tier JIT) because metalava is short-running enough that aggressive JIT would never pay back. Even with those flags, JVM cold-start is a real cost.
2. **Classpath load**: ~1 second. metalava loads its UAST/PSI infrastructure plus the classpath jars (sometimes hundreds of MB of jars on big framework runs).
3. **Source parse**: variable. For a small module like `framework-permission`, ~2 seconds. For framework-core proper (~500K lines of Java), this is closer to 10-15 seconds. metalava uses IntelliJ's UAST resolver under the hood — UAST stands for "Unified AST," the abstract syntax tree IntelliJ uses to represent both Java and Kotlin source in a single shape, sitting on top of PSI ("Program Structure Interface"), IntelliJ's lower-level parsed-source representation. Both are heavy but correct: they handle every corner of the language that a real IDE would, which is more than most ad-hoc Java parsers.
4. **AST walk + API extraction**: variable. For framework, dominant — ~10-20 seconds.
5. **Compatibility check**: ~1-5 seconds. metalava diffs the new API against the pinned `current.txt`/`system-current.txt`. Flags four kinds of incompatibility (added/removed/changed/deprecated). Walks the same AST in a different traversal.
6. **Stub emit**: a few seconds. Walk the API surface, emit `.java` files containing just signatures, package them into a `.srcjar`.
7. **Annotation extraction**: ~1 second. Walk the AST again for annotation metadata, write `.annotations.zip`.
8. **JVM teardown**: instant, but the 30-60 seconds you just spent are gone.

For a small framework like `framework-permission`, this is ~20-30s. For framework-core, multiple SDK levels each producing their own metalava action, you can spend 4-5 minutes of cold build wall time inside metalava alone. The fact that 298 of these run per cold build, mostly independently, means metalava is one of the single largest contributors to total cold build wall time — easily 30+ minutes in aggregate across the whole tree.

### Why this is a daemon-mode shaped problem

Almost everything in that 30-second run is *amortizable*. JVM startup is amortizable (keep the JVM warm). Classpath load is amortizable (keep the resolver state warm). The PSI/UAST resolver, once loaded, can incrementally re-parse only changed files. Even the compatibility check is amortizable: if the previous run's API output hash is the same, the compatibility result is the same.

A daemon-mode metalava prototype (the `metalava-daemon` directory in `tools/metalava/`) does exactly this. Run it once; keep it running; for each subsequent invocation, send a small RPC saying "here are the changed files, recompute." The amortized per-invocation cost drops from ~30s to a few hundred milliseconds. The prototype works. Wiring it into Soong as a persistent worker (per chapter 67) and replacing every `out/host/linux-x86/bin/metalava` invocation with a daemon call would save tens of minutes per cold framework build, and a substantial fraction of every inner-loop Java edit.

This is the single highest-impact warm-Java fix available, and the code is mostly already written. What is missing is the integration layer: a long-lived process supervisor in Soong, a protocol for re-invocation, and the discipline of keeping the daemon's invalidation logic correct against subtle changes (e.g., a flag change between invocations).

## 36. R8 and shrinking

R8 is the code-shrinker / optimizer / obfuscator. After javac and before dexing, R8 takes the compiled classes and:

* Removes unused classes, methods, fields (tree-shaking).
* Optimizes (inlining, simplification).
* Obfuscates names (for app releases — not for AOSP itself).

R8 only runs when configured to (release builds, certain APEXes). For a typical inner loop on framework code, R8 is not in the path. For app builds (Android Studio, Gradle) it is, and it can take many seconds.

R8's incremental story is okay but not great. Caching by classes-in-jar hash is doable but not always reliable; tracking what was tree-shaken in past runs requires careful state.

## 37. d8 and dexing

After javac produces JVM bytecode, d8 converts it to DEX (the Dalvik/ART bytecode format Android actually runs). d8 is fast for small jars and gets slower for large ones. For framework-core, dexing a single jar can take 5-15 seconds.

There is per-class dexing — d8 can dex one class at a time and merge the results. This is what Gradle's incremental dex does. Soong's current dex path is whole-jar; switching to incremental dex would help, but the bigger savings are at the javac/metalava layer.

## 38. Header jars and Turbine

Java has an implementation-ABI distinction. If you depend on library X, your compile-time only needs X's *signatures* (the class names, method signatures, field declarations), not their implementations. The implementations are needed at link/run time but not compile time.

Soong (and Bazel, Buck2, modern Gradle) generates **header jars** — stripped-down versions of jars containing only the public API surface. The tool that produces these is called **Turbine**. Turbine parses Java but skips method-body compilation and most type-checking, emitting only the API surface (class names, method signatures, field declarations). It is dramatically faster than full javac for the same reason a phone book is faster to print than a novel: most of the heavy work has been skipped on purpose.

Compiling against header jars means: when you edit a private method body in library X, downstream consumers' compilations don't have to re-run, because X's header jar didn't change. This is enormous for incremental Java builds.

Turbine has its own incremental and caching story; in Soong it's already wired up. Mostly out of the critical path for the warm-build work.

## 39. Resource processing (aapt2)

For Android apps and frameworks with resources (drawables, strings, layouts), `aapt2` runs to compile resources into a binary format the platform can load efficiently. aapt2 also generates `R.java`, the class with constants for every resource ID.

aapt2 is fast (sub-second per module typically), but resource changes are common (string edits, drawable swaps), and the resource processing of the framework adds tens of seconds to a cold build.

aapt2 has decent incremental support; per-resource hashing avoids redoing work when individual resources are unchanged.

## 40. AIDL/HIDL codegen

AIDL (Android Interface Definition Language) is how processes talk to each other on Android (Binder IPC). Each `.aidl` file is processed by an AIDL compiler that emits Java stub classes (and increasingly C++ / Rust stubs too).

For framework Android.bp files that reference `.aidl` srcs, the build runs AIDL codegen, then compiles the resulting Java alongside the hand-written code. AIDL codegen itself is fast (~ms per file), but there are thousands of AIDL files in framework, so it adds up.

HIDL (the older equivalent for hardware interfaces) is being phased out in favor of AIDL.

## 41. APEX assembly

APEX is Android's packaging format for shipping platform pieces independently of the OS image. Each APEX is essentially a self-contained partition image with a small filesystem inside it.

Building an APEX involves:

1. Building every module that belongs to the APEX (each as an apex-internal variant).
2. Assembling the contents into a filesystem image.
3. Signing the APEX.
4. Emitting the APEX file (effectively a zip containing the filesystem image and metadata).

APEX assembly is slow (~tens of seconds per APEX) because of step 2 (image construction) and step 3 (signing). For the dozens of APEXes in a modern Android system, this is several minutes of cold build time.

Incremental APEX assembly is hard because filesystem images are bulk operations. If a single module inside an APEX changes, the whole image is repacked. Some work has gone into making this incremental at the file level (only repack files that changed), but the image format is fundamentally bulk.

## 42. dexpreopt

The final step in a system image build is **dexpreopt** — invoking `dex2oat` on the dex files to produce pre-compiled `.odex` and `.vdex` files that ART can load immediately at boot, without having to JIT-compile on the device.

dex2oat is slow. For framework code, ahead-of-time compilation can take many minutes. It runs on the host as part of the build.

For inner-loop development, dexpreopt is usually skipped (`USE_DEX_PREOPT=false`), and the runtime JIT picks up the slack. For release builds, it's mandatory.

---

# Part VIII — Why incremental analysis is hard

## 43. The six structural obstacles

The naive idea for incremental analysis: keep Soong's resolved module graph in memory; on a `.bp` edit, re-run only the affected analysis; splice the updated ninja into the manifest; have Ninja re-execute only what's downstream of the change.

This works only if the rest of the graph is genuinely stable when one module changes. It usually isn't. Six structural reasons:

1. **Mutators are whole-graph.** A change to one module's properties could in principle change variant counts, dep edges, defaults expansions across the graph.
2. **Singletons aggregate over the whole module set.** Adding, removing, or modifying any module changes every singleton's output.
3. **Providers couple modules.** If a module's exported provider changes, every dependent's build actions might change.
4. **Accumulated state** from previous builds (dedup decisions, package names, position counters) can go stale.
5. **Source positions shift** when you add or remove lines.
6. **The faithfulness problem**: how do you *know* the warm result equals a cold result for the same inputs, without doing the cold build to compare?

These are not independent. Fixing one often surfaces another. The work I did over the last while was: take a coherent position on each of these six points and verify the result with a byte-by-byte gate.

Let me walk through each in detail.

## 44. Mutators revisited

Mutators are functions written in arbitrary Go that run over every module and may transform the module set. They are whole-graph, not per-module.

Why do they fight incremental analysis so badly?

* **A mutator may behave differently for module A depending on the state of module Z.** The arch mutator splits `libfoo` into arm64 and arm32 variants depending on what arches are configured for the device — but also depending on whether some consumer says "I only want arm64 of you," which is a cross-module signal.
* **A mutator mutates the graph itself.** The arch mutator's job is literally to add new modules. The apex mutator creates additional variants by reading apex membership lists elsewhere. After mutator N runs, the graph has more nodes and different edges than before. There is no clean "checkpoint" to return to.
* **A mutator can create entirely new modules at runtime.** The `java_sdk_library` machinery takes one declaration and spawns half a dozen stubs modules under different names. The `filesystem_creator` machinery generates a synthetic device module representing the final filesystem image. These don't exist in any `.bp` file; they exist only because some other module's code called `CreateModule`.

Putting these together: re-running a mutator incrementally on a single changed module is hazardous. It might create things that already exist (crash). It might silently fail to propagate to consumers that need to be updated.

Soong does have a sub-system for "incremental mutation" (`incremental_mutation.go`). It classifies mutators as **non-coalescable** when they contribute to properties that are unsafe to replay (the sanitizer mutator and the LTO mutator are the canonical examples — both add per-module properties whose re-derivation requires whole-graph reasoning). Anything not flagged non-coalescable is safe to replay in isolation. When an edit touches a property whose downstream mutators include a non-coalescable one, the warm path falls back; otherwise it replays the rest. In practice, for common warm edits (property changes, srcs changes, comment edits), the changed module's coalescable mutators can be replayed in isolation, AND the non-coalescable ones don't have to be touched. This is what makes incremental analysis feasible for those cases.

### What "re-running a mutator" actually breaks

The first time I tried to re-run the arch mutator on a single changed module — call it `libfoo` — Soong died with:

```
panic: arch mutator: more than 1 main variant for "libfoo"
```

The stack trace pointed at an invariant check inside Blueprint's mutator runtime: each module name is supposed to have exactly one "main" variant after the arch mutator finishes, and the runtime crashes if it finds two. Reading the trace, the obvious interpretation was "the arch mutator is buggy on the re-derive path." That was wrong.

The actual story: the arch mutator's job is to split a multi-arch module into one variant per arch the device supports (`arm`, `arm64`, `x86`, `x86_64`). Internally, it does this by calling Blueprint's `CreateVariations` API with the list of arches; Blueprint allocates new `moduleInfo` structs for each variant, links them into the module-group's list of variants, and updates an internal map of `(group, arch) -> moduleInfo` so that downstream consumers can resolve which variant to depend on.

When I re-ran the arch mutator on just `libfoo` after a properties edit, the existing variants from the cold pass were still in the module group. The arch mutator, doing what arch mutators do, called `CreateVariations` again with the same list of arches. Blueprint allocated *new* variants. Now the module group had two arm64 variants, two arm variants, etc. — the cold ones still there from before, plus the new ones the re-derive just added. The "more than 1 main variant" check was a guard against exactly this kind of double-creation.

So the panic was correct. The arch mutator was doing exactly what it was designed to do. The bug was that I had asked Blueprint to *re-do* a creation operation whose output was supposed to be permanent.

The fix in principle is straightforward: before re-running the arch mutator, clear the existing variants from the module group so the new variants take their place. The fix in practice is brittle. The variants list is owned by Blueprint, not the mutator. The arch mutator has no API to say "tear down the previous arch split first." The dependencies into the existing variants — every consumer module that resolved `libfoo` to a specific variant during the cold pass — would all be left pointing at moduleInfos that no longer existed. Some other mutator that ran after arch might have annotated those moduleInfos with state Blueprint expects to find later. Tearing down "just the arch variants" was not a localized operation.

I spent two days writing increasingly elaborate cleanup code before I realized I was solving the wrong problem. The fix wasn't "make re-running the arch mutator work." The fix was "don't re-run mutators that create variants in the first place." The list of arches `libfoo` is built for didn't change between the cold pass and the warm edit; the variants that existed are still the right variants; the right thing to do is *skip* the arch mutator entirely on the warm path and keep the cold pass's results.

This is what Soong's "coalescable" classification of mutators does. Mutators are tagged with whether their output for a given module depends only on that module's properties (safe to replay) or also on global state including previously-created variants (unsafe to replay). The arch mutator is in the "unsafe" category. For most warm edits — property changes that don't affect arch selection — the warm path can keep the cold pass's arch variants and skip the mutator entirely. Only mutators whose decisions might have *changed* need to re-run. And if a non-coalescable mutator's decision *would* change for the edit at hand, the warm path falls back to a full cold rebuild.

This is fine. The fallback is rare in real iteration patterns — comment edits, srcs reorders, defaults tweaks all leave arch selection alone — but it is correct when it triggers. The category is the safety mechanism.

The deeper lesson, which I keep relearning: not every operation a system can do is safe to do twice. The mutator pipeline's design assumes one-shot execution from a known starting state. Re-running it on a partial graph is not a slightly-different mode of the same operation; it is a fundamentally different operation that the existing code is not equipped to perform. The clean fix isn't to make the existing code re-runnable — that would require touching every mutator and every internal invariant Blueprint relies on. The clean fix is to identify which operations *can* safely be redone (most of them, fortunately) and ring-fence the ones that can't behind a fallback. Which is what `incremental_mutation.go` ultimately does, after a fashion.

For less-common edits (variant settings, apex membership), the incremental path doesn't try; it falls back to full cold rebuild. Correct, just slow.

## 45. Singletons revisited

Singletons aggregate over the whole module set. They are single-use in Soong.

The pain concentrates when a module is added or removed. Adding a module means:

* `module-info.json` needs one more row.
* The `all-modules` phony needs one more installed target.
* The license-graph needs one more node and any transitive edges.
* Packaging needs to know if the new module installs into a partition.
* Etc.

To produce these correctly, you have to re-run the singletons or compute the deltas directly.

Re-running naively fails: Soong's singletons assume `GenerateBuildActions` runs once. They use `sync.Once`. They set providers. They consume state. A naive "reset and re-run" produces empty output or double-sets a provider and panics. **This is now solved** by resetting each single-use singleton's generate-state (its `actionDefs`, its providers, and its run guards) before re-running it over the new module set on a membership change — so add and remove are warm and byte-identical to a cold resident rebuild. What is *not* yet done is making that re-run cheap (below).

The graph side of a membership change is already built — the resident server has `IncrementalAddModules` / `IncrementalRemoveModules`. The only blocker is the singletons. The aggregations are per-module *additive*: the phony singleton is literally `VisitAllModuleProxies(m -> for k,v in m.Phonies: phonyMap[k] += v)`, so adding a module appends its entries and removing one drops them, with no other module's contribution changing. `module-info` has the same shape — one entry per module.

The open piece is to express each singleton as an **incremental fold**: record every module's per-singleton contribution during the full build; define a per-singleton fold function (`sort-and-concat` for `module-info`, set-union for `all-modules`, graph-edge-merge for license-graph); on a membership change, just add/remove the contribution and recompute the fold. This is tractable: the additive singletons fold trivially. Only pathological non-additive singletons (a global sorted index, cross-module dedup with global numbering, a whole-tree hash) and the license graph's transitive closure are non-trivial.

An alternative to folding each singleton — the one actually landed — is the
**contribution probe**: instead of expressing each singleton's fold, just *detect*
that the added module contributes nothing to it (run it over the changed set vs the
empty set; equal ⇒ keep the resident output) and skip it. This is additive-singleton
exact and needs no per-singleton code. On the f/b add it skips 65 of 66 singletons,
taking regen+write from 17.2 s to 9.8 s, byte-identical. A *remove* still re-runs
(the probe can't observe a subtracted contribution), so the per-singleton fold is
still the right tool there.

Until the probe overhead and the write are also cut, add is warm but not yet
sub-second: 9.8 s of regen+write (broken down in the SUMMARY), the output
byte-identical to a cold resident rebuild. (The soong-only phony singleton now
does the pure-add fold — it keeps the cached module phonies and re-derives only
the keys whose contributing modules changed, falling back to a full scan only if a
singleton-emitted phony changed. `testsuites`, `soongonlyandroidmk`, and the
global order-only dedup in the write are the remaining whole-tree costs.)

## 46. Providers and propagation

Modules read each other's providers during `GenerateBuildActions`. If module B's exported provider changes, module A (which depends on B) might emit different ninja text.

How to propagate?

Soong has a clean mechanism. After a module's `GenerateBuildActions` runs incrementally, the system hashes the module's exported provider state. It compares the hash to the previous full build's. If different, `interfaceChanged` is set true. The generate-targeted scheduler adds the module's direct reverse-dependents to the regen list. Those run; if THEIR interface changes, propagation continues. If their interface hash is the same, propagation stops.

This is the right design. It is precise: only modules whose actual exposed state changed cause propagation.

I learned this the hard way. I originally wrote a crude "dirty every transitive reverse dep" closure. It worked on simple cases. On a real frameworks/base edit, it propagated into `filesystem_creator` and crashed when it tried to re-create the device module (duplicate creation). I removed my crude closure and let Soong's built-in `interfaceChanged` propagation do its precise job.

## 47. Accumulated state — dedup, naming, position

Some state in Soong persists across builds and isn't updated when the underlying graph changes. When that happens, the build silently goes wrong.

**Order-only dep dedup.** Many ninja build statements have an "order-only" dependency list. Soong notices when several modules share the same list and rewrites them to share a `dedup-<hash>` phony aggregator. Originally this rewrite was *destructive*: the original list was lost. On a warm build, the dedup decisions could change (a module disappeared from the group), but the rewritten statements still referenced the old phony. Dangling references; ninja crashes.

The fix (chapter 51): make dedup *non-destructive* and *content-addressed*. Every `buildDef` keeps its original order-only list immutably. The dedup pass recomputes from scratch each build. Dedup names are content hashes of the sorted key. The rewrite is a derivation, not a mutation.

**Package name collisions.** Soong assigns short or long names to package-level variables based on collisions in the *live* set. On warm builds, the live set is a subset of cold's; collisions resolve differently; names diverge from cold; references go dangling.

The fix (chapter 52): preserve the previous full build's complete `liveGlobals` set across builds. Collision detection sees the same set.

**Position dependence.** When Soong emits a module's build actions, it includes a debug header: `# Defined: file:line`. The line number is read from `module.pos` at write time. If you delete a line from a `.bp`, every module below shifts up by one line. Cold rebuilds emit new line numbers; warm doesn't re-emit content-unchanged modules.

The fix (chapter 55): track position shifts; mark content-unchanged but position-shifted modules for re-serialization.

## 48. The faithfulness problem

The deepest of the six. After incremental re-derivation has run, the question is: did we get it right?

Soong's safety mechanism is `inPlaceFaithful`. It compares the re-derived module state against a reference snapshot. If they match, the warm result is trusted; if not, fall back to cold.

The implementation had a subtle bug. The original check compared re-derived state to the *live* state in the resident graph. But the live state includes things `GenerateBuildActions` ADDED (license fields, etc.) — and the re-derive only runs mutators, not generate. The comparison was apples-to-oranges: the live state had stuff the re-derive could never produce.

Result: every real edit failed the faithfulness check and fell back to cold.

The fix (chapter 50): compare against `pristineProperties` — a deep copy of each module's state captured at the post-mutate / pre-generate boundary. Structurally apples-to-apples with the re-derive's output. Faithful re-derives are correctly recognized.

That fix alone moved comment/reorder/dropsrc edits from "always fall back" to "engage incremental." The other fixes became necessary to make the engaged path byte-correct.

---

# Part IX — What I tried

## 49. The byte-verification corpus

Before describing the fixes: the gate.

The corpus (`/tmp/fb_corpus.sh`) is a test harness. For each edit kind it applies the edit to a real `frameworks/base/Android.bp`, performs a warm build, performs a cold build of the same edited tree, snapshots both manifests, byte-compares. Output: per-edit-kind ENGAGED/FALLBACK and BYTE-IDENTICAL PASS/FAIL.

Edit kinds:

* **comment**: append a no-op comment.
* **reorder**: swap two adjacent srcs entries in a filegroup.
* **dropsrc**: delete one srcs entry from a filegroup.
* **addmod**: append a new filegroup module.

Byte-comparison is the **gate**. A fix that makes a kind engage but not byte-identical is a miscompile and is rejected. A fix that regresses a previously-passing kind is reverted, no matter how clever.

This was the most important meta-tool of the entire effort. Without it, the work would have been a leap of faith. With it, every fix could be empirically validated against ground truth.

A daily cron runs the corpus.

## 50. Fix 1 — Faithfulness baseline

The most important fix.

**Symptom:** every real edit fell back to cold.
**Reading:** every edit hit `inPlaceFaithful`, the check returned false, code fell back.
**Dig:** the check compared re-derived state to the *live* state. Live state includes generate-time additions. Re-derive does not run generate. Apples-to-oranges.
**Fix:** compare against `pristineProperties`, captured at the post-mutate / pre-generate boundary.

### How I actually found it

I want to tell this one as a story, because it is the moment where the entire warm path went from "exists in theory" to "exists in practice." For weeks before this, the resident soong_build infrastructure was a dead letter — beautifully implemented machinery for re-mutating individual modules incrementally, sitting behind a faithfulness check that returned false on every single real edit. The infrastructure existed. It just never engaged. From the outside, the build looked identical to a cold build, except you also paid the cost of *running* the incremental code path before throwing its result away.

The first day I sat down to debug this, I did the obvious thing: I added a print statement inside `inPlaceFaithful` that dumped, for each property of the changed module, the re-derived value vs the reference value, plus a line saying which one was being treated as canonical. I edited one Android.bp file with a comment change — the most trivial edit possible, no semantic content — and ran the warm build. The output looked like this (lightly redacted):

```
inPlaceFaithful: re-derive complete for "framework-foo"
  property "Srcs":                MATCH
  property "Static_libs":         MATCH
  property "Sdk_version":         MATCH
  property "Defaults":            MATCH
  property "Name":                MATCH
  property "Licenses":            MISMATCH
    live  = ["legacy_notice", "Android-Apache-2.0"]
    derived = []
  -> returning false (fallback to cold)
```

Every property matched except `Licenses`. The re-derived state had an empty license list; the live state had two licenses. I spent half a day chasing this as if it were a normal bug. Was the re-derive failing to run the license mutator? Was the license mutator getting confused by the partial graph? Was something in the resident state being mutated mid-derive?

None of those. The actual answer was structurally simpler and made me feel slow. I went looking for *where* the `Licenses` property was set on a module. It was not set in any `Android.bp` file. It was not set by any mutator. It was set inside `GenerateBuildActions` — specifically inside Soong's license handler, which during a module's generate phase reads the surrounding `license_kind` modules, computes the transitive closure, and stamps the resulting list into the module's own `Licenses` property as a derived field.

So the live state's `Licenses` had two entries because cold's `GenerateBuildActions` had run for that module and stamped them in. The re-derived state's `Licenses` was empty because the re-derive *only ran mutators*, not `GenerateBuildActions`. The faithfulness check was, structurally, comparing post-mutate state (the re-derive's output) to post-generate state (the resident live state). The re-derive could never produce the `Licenses` field because producing it requires running code the re-derive deliberately doesn't run. The mismatch wasn't a bug in any individual piece of code; it was a category error in what the check was *comparing*.

The fix took ten minutes once I understood it. Soong already had a notion of "pristine properties" — a deep copy of each module's state captured by `cloneModules` immediately after mutators ran and before generate. Originally it was used for something else entirely (snapshotting for SBOMs, I think). I changed `inPlaceFaithful` to compare against `pristineProperties` instead of the live properties, set a flag (`keepPristineModules = true`) in `BeginIncrementalBuild` so the snapshots would actually be kept, and reran the corpus.

The first edit engaged. Then the next. Then the next. Six weeks of "every edit falls back" became, in one commit, "every edit engages." The incremental path I had been building for weeks suddenly had a heartbeat. Other things broke immediately after — Fix 2 through Fix 6 in this part are all consequences of the engaged path now actually being exercised — but those were *new* bugs caused by warm code paths running for the first time, not the same dead-letter problem.

The lesson I took: when a structural check is failing universally, it is not usually a per-case bug. It is the check itself comparing the wrong things. The week of print-statement spelunking I did before this point was wasted; the structural reframing I should have done in the first hour would have shown me the same answer faster. I have caught myself in this same mode several times since. Whenever I am chasing field-level mismatches in a check that "ought to" succeed, the right question is not "which field is wrong" but "what does the check *think* it's comparing, and is that the same thing as what it's *actually* comparing." Usually the answer to question two is no.

Code (in `build/blueprint/incremental_mutation.go`; this listing is simplified — the real function also emits fallback-diagnostic logs and handles a couple of edge cases I've trimmed for clarity):

```go
func (c *Context) inPlaceFaithful(config interface{},
    changedGroups []changedGroup) (bool, error) {
    want := map[*moduleInfo]uint64{}
    for _, cg := range changedGroups {
        for _, v := range cg.group.modules {
            if v.pristineProperties == nil {
                return false, nil
            }
            h, err := proptools.CalculateHashTolerant(v.pristineProperties)
            if err != nil {
                return false, err
            }
            want[v] = h
        }
    }
    if _, _, _, errs := c.reDeriveInPlace(config, changedGroups);
       len(errs) > 0 {
        return false, nil
    }
    for v, h := range want {
        nh, err := proptools.CalculateHashTolerant(v.properties)
        if err != nil { return false, err }
        if nh != h {
            return false, nil
        }
    }
    return true, nil
}
```

Snapshot before re-derive; re-derive; compare against snapshot. Apples-to-apples.

Result: comment, reorder, dropsrc edits now engage. addmod also engages but does not yet pass byte-equality (singletons).

This was Fix 1, the entry-point. The other fixes were each specific consequences of the engaged path now being exercised.

## 51. Fix 2 — Non-destructive content-addressed dedup

After Fix 1, the edited warm output was wrong: dangling references to `dedup-<hash>` phonies. Ninja crashed.

**Reading:** order-only dedup was destructively rewriting `buildDef` in place. The rewrite was sticky across builds. Dedup decisions weren't re-derived on warm.

**Fix:** every `buildDef` keeps an immutable `OrderOnlyOriginal`. The dedup pass runs from scratch each build. Dedup decisions recomputed (dedup iff —2 statements share a key). The dedup *name* is a content hash. The rewrite is non-destructive: at emit time, the effective `OrderOnlyStrings` is derived from `OrderOnlyOriginal` plus the current dedup table.

Code in `ninja_defs.go` (the `uniquelist.UniqueList[string]` type below is a Blueprint helper for memory-efficient deduplicated string lists — many buildDefs share the same lists, so Blueprint stores them once and hands out shared handles):

```go
type buildDef struct {
    // ...
    OrderOnlyStrings  uniquelist.UniqueList[string]
    OrderOnlyOriginal uniquelist.UniqueList[string]
    // ...
}
```

In `parseBuildParams`:

```go
b.OrderOnlyStrings = uniquelist.Make(orderOnlyStrings)
b.OrderOnlyOriginal = b.OrderOnlyStrings  // immutable copy
```

`OrderOnlyOriginal` is set ONCE at parse time. Never written to again.

The dedup pass in `context.go`:

```go
counts := map[uniquelist.UniqueList[string]]*keyInfo{}
for _, m := range modules {
    for _, def := range m.actionDefs.buildDefs {
        if def.OrderOnlyOriginal.Len() == 0 {
            continue
        }
        bump(def.OrderOnlyOriginal, ...)
    }
}

dedupName := map[uniquelist.UniqueList[string]]string{}
for key, ki := range counts {
    if ki.count < 2 {
        continue
    }
    name := fmt.Sprintf("dedup-%x", keyForPhonyCandidate(key.ToSlice()))
    dedupName[key] = name
    // emit phony for `name` aggregating key.ToSlice()
}

for _, def := range m.actionDefs.buildDefs {
    if name, ok := dedupName[def.OrderOnlyOriginal]; ok {
        def.OrderOnlyStrings = uniquelist.Make([]string{name})
    } else {
        def.OrderOnlyStrings = def.OrderOnlyOriginal
    }
}
```

Destructive rewrite gone. Each build computes the dedup table fresh and applies it as a derivation. No stale state.

Result: dedup-related ninja crashes gone. Warm shards' dedup references match cold.

## 52. Fix 3 — Deterministic package names

After Fix 2, a different crash: warm shards referenced `${g.config.JavacCmd}` where cold referenced `${g.android.soong.java.config.JavacCmd}`. Dangling refs.

**Reading:** `makeUniquePackageNames` computes short-vs-long names based on the *live* globals set. Warm's live set was a subset of cold's; collisions resolved differently.

**Fix:** in `BeginIncrementalBuild`, set `c.preserveLiveGlobals = true`. Keep the previous full build's complete `liveGlobals`. (The real `BeginIncrementalBuild` also clears each module's `interfaceChanged` flag — load-bearing for Fix 4 below, since the precise propagation needs a clean baseline.)

```go
func (c *Context) BeginIncrementalBuild() {
    c.dirtyModules = map[*moduleInfo]bool{}
    c.forceNinjaWrite = false
    c.membershipChanged = false
    c.regeneratedModules = nil
    c.preserveLiveGlobals = true                    // <-- fix
    c.posShiftedModules = map[*moduleInfo]bool{}
    for m := range c.iterateAllVariants() {
        m.interfaceChanged = false                  // baseline for Fix 4
    }
    // ...
}
```

`makeUniquePackageNames` runs against the same set cold ran against; produces same names.

Result: no more package-namespace-related ninja crashes. Warm and cold agree on variable names.

## 53. Fix 4 — Precise propagation via interfaceChanged

After Fix 3, byte-diffs in some warm shards: consumer modules of an edited filegroup still showed OLD srcs order; they hadn't been regenerated.

**Reading:** I had originally written a crude "dirty all transitive reverse deps" closure. Worked for simple cases. On a real filegroup edit, propagated through a filegroup-of-filegroups chain, hit `soong_filesystem_creator`. Re-running it re-created the device module. Soong errored: "more than 1 main `android_device` module."

**Fix:** stop hand-rolling propagation. Soong has a precise mechanism via `interfaceChanged`. After a module's `GenerateBuildActions` runs, hash its exported provider state. If different from previous, set `interfaceChanged = true`. The generate-targeted scheduler propagates by adding direct reverse deps of modules with `interfaceChanged`.

I removed my crude closure (in `build/soong/cmd/soong_build/main.go`'s `runBuildReuse`). The built-in mechanism takes over.

```go
// (before) ctx.ExpandDirtyWithReverseDeps()
// (after) — propagation handled inside generateTargeted via
// interfaceChanged. No manual closure here.
```

Result: precise propagation. Filegroup edits propagate to direct consumers (IPsec impl variants), and stop at modules whose external interface didn't change.

## 54. Fix 5 — Delta write keyed on the regenerated set

After Fix 4, a more subtle byte-diff. The propagated modules WERE regenerating in memory but their new build actions weren't getting written. The shard containing them was being SKIPPED in the delta-write.

**Reading:** `shardHasDirtyModule` — the function that decides whether a shard's on-disk file needs rewriting — was checking `c.dirtyModules`. But propagated modules (added via `interfaceChanged`) are in `c.regeneratedModules`, NOT `c.dirtyModules`. `shardHasDirtyModule` returned false for shards containing them. New bytes were discarded; old cached bytes written instead.

**Fix:** introduce `wasRegenerated()` checking both sets (and `posShiftedModules` from Fix 6).

```go
func (c *Context) wasRegenerated(m *moduleInfo) bool {
    if c.posShiftedModules[m] {
        return true
    }
    if c.regeneratedModules != nil {
        return c.regeneratedModules[m]
    }
    return c.dirtyModules[m]
}

func (c *Context) shardHasDirtyModule(batch []*moduleInfo) bool {
    for _, m := range batch {
        if c.wasRegenerated(m) {
            return true
        }
    }
    return false
}
```

And in the per-module text-cache reuse loop:

```go
dirty := c.dirtyModules != nil && c.wasRegenerated(module)
if !ok || dirty {
    // re-serialize this module's ninja text
} else {
    // reuse cached bytes
}
```

Result: propagated modules' new build actions correctly written. Corpus passes byte-identical on reorder/dropsrc.

## 55. Fix 6 — Position-shift re-serialize

After Fix 5, remaining byte-diff for dropsrc: clean modules shifted by the line removal had stale `# Defined:` line numbers.

**Reading:** modules below a deleted line have new positions, but warm doesn't re-emit content-unchanged modules.

**Fix:** in `DiffParsedModules`, after matching reparsed modules to baselines, also call `updatePos` for each match. If position shifted, update the resident variants' `pos` field and add to `c.posShiftedModules`. `wasRegenerated()` returns true for those, so delta-write re-serializes them.

```go
updatePos := func(name string, newPos scanner.Position) {
    rg := c.moduleGroupFromName(name, nil)
    if rg == nil || len(rg.modules) == 0 {
        return
    }
    cur := rg.modules[0].pos
    if cur.Line == newPos.Line &&
       cur.Column == newPos.Column &&
       cur.Filename == newPos.Filename {
        return
    }
    for _, v := range rg.modules {
        v.pos = newPos
        c.posShiftedModules[v] = true
    }
}
```

Result: dropsrc shards' position comments match cold. Corpus passes.

## 56. The standalone engine

In parallel with the Soong patches, I built a separate, clean-slate incremental computation engine — about 700 lines of Go plus a demo driver. It is a *separate exploration of a future redesign* and is **not part of the patches in this repo** (the patches are the warm-incremental Soong daemon only); it is described here because it shows what enforcing the pure-function invariant by construction looks like.

The engine's design:

* Every value is the output of a PURE memoized query keyed on the hashes of its inputs.
* Each query records, automatically, the other queries it read while computing.
* On an input change, queries are re-evaluated lazily, only when transitively reached from a changed input.
* When a query is re-evaluated and produces an unchanged output hash, downstream queries that depended on it are NOT invalidated. This is **early cutoff**.

Compared to Soong: no mutators (variants emerge as queries on demand). No singletons (aggregations are folds over recorded contributions). No providers (cross-module data flows via query results). No faithfulness checks (architecture makes correctness automatic).

On real frameworks/base (974 `Android.bp` files, ~10,000 query nodes):

| Edit | Time | Byte-identical to cold? |
|---|---|---|
| Cold (full parse + analyze) | 220 ms | (baseline) |
| Reorder srcs in a filegroup | 9 ms | yes |
| Cross-module defaults edit (`*_defaults`) | 17 ms | yes |
| Add a new module | 8 ms | yes |

All cases byte-identical to a cold build. The engine CANNOT fall back.

The catch: the engine's "ninja" is simplified — content-addressed phony stamps that prove the architecture works on a real dependency graph, but do not actually drive a build. Turning it into a real backend for AOSP would mean expressing every module type's `GenerateBuildActions` as queries. Multi-year project across hundreds of module types.

The engine is committed on the same branch as the Soong patches. It is the strategic answer; the patches are the tactical wins shipped today.

## 57. Things I tried and reverted

For honesty.

* **Debug-print spelunking inside `inPlaceFaithful`.** Tried to chase the diff field by field. Wrong tool. The fix was structural (use `pristineProperties`), not surgical. Lesson: don't chase symptoms when the design says you're comparing the wrong things.

* **A crude "dirty every transitive reverse dep" closure.** Worked in my head, crashed in practice (createModule double-creation). Soong's interfaceChanged is precise and correct; manual closures aren't.

* **A blanket fallback on any cross-module edit.** Too coarse; would have falsely demoted reorder and dropsrc to fallback. Discarded once precise fixes worked.

The pattern: when I was thinking surgically ("how do I patch this symptom"), I introduced bugs. When I was thinking structurally ("what invariant is being violated"), the fixes worked.

---

# Part X — Proposed designs: a real path to millisecond overhead

This part is the most forward-looking. None of it is shipped. All of it is feasible. The order is roughly cost-effectiveness — biggest wins first.

## 58. Incremental singletons and the membership-change path

Adding a module is warm and byte-identical; removing one still falls back. The
graph side is incremental either way (the resident server has
`IncrementalAddModules` / `IncrementalRemoveModules`); the work is in the
whole-graph singletons.

Only seven singletons actually run in an inner-loop `nothing` analysis, and two
dominate: `phony` (~6.7s) and the soong-only `androidmk`/module-info aggregator
(~2.7s); the rest (`rawfiles`, `all_aconfig_declarations`, `bootstrap`,
`makevars`, `ninjadeps`) are sub-second. The ~50 other registered singletons are
dist / IDE / codegen passes that do not run in the inner loop.

These singletons are single-use: re-running one on the resident graph without
clearing its state double-sets its providers and panics (`provenance_metadata`,
`all_aconfig_declarations` do exactly this). So on a membership change each
singleton's per-build generate-state -- its merged build defs, its providers, the
started/finished guards -- is reset before the re-run, which makes the re-run
clean and byte-identical to a cold run. With that, adding a module is warm.

The manifest write stays O(edit) across the add because shard assignment is
content-addressed (a stable hash of each module's identity), not position-based:
inserting a module leaves every other module in its shard, so the add rewrites
exactly the one shard the new module hashes to (1 of 50), not all of them.

Folding the aggregation alone is NOT enough. Measured, the phony singleton's
~7s on a 600 MB / 753k-key output splits into roughly thirds: scan+sort ~3.1s,
string-build ~2.6s, file-write ~1.6s. Skipping just the scan leaves the emit. So
the fix is BOTH: keep the cached sorted map and re-sort only the added module's
keys (kills the scan+sort), AND content-address-shard the output by key into N
files so a warm add rewrites only the shards whose keys changed (kills the emit).
This is built and verified for phony: `soong_phony_targets.mk` is sharded into 64
files (glob-included by the packaging makefile), and a warm add drops phony from
~7s to milliseconds, byte-identical to cold across all 64 shards. `androidmk`
(module-info, ~86 MB JSON consumed by a merge tool) is the same shape, with the
extra step of teaching that tool to read shards.

Removing a module is also warm now. The name interface gained `RemoveModule`
(it previously lacked the optional `ModuleRemover`, which forced a full rebuild),
and because a removed module is gone from the set its shard would look clean and
be skipped -- so its stable-hash shard index is force-marked dirty and rewritten
to drop the deleted module. A real remove engages the warm path (1 shard
rewritten) and is byte-identical to cold.

So today, all three edit classes are warm and byte-identical on real AOSP:
property edit, add-module, and remove-module, each with an O(edit) manifest write.
The remaining work to single-digit is finishing the incremental singleton emit
(phony done; androidmk next) and the wall overhead -- dumpvars and the ninja
manifest reload.

**Update (v0.8): the soong-side regenerate+write is now sub-second to ~1.3s, not
~4.4s.** Three things were re-serializing or recomputing over the whole tree on
every warm build, none of which an edit actually changes: the order-only dedup
(O(tree) recount + a re-serialize of the ~60%-of-manifest phonys subninja), the
singletons subninja (~40% of the manifest, re-serialized just to hash-check it was
unchanged), and the sorted+content-addressed-sharded module lists. Cache each, keyed
on what genuinely changed (a per-module order-only *fingerprint* for the dedup; the
probe-kept set for singletons; pointer-identity of the module set for the sort/shard
layout), and they collapse to O(edit): dedup 1.1s→1ms, singletons 0.9s→<1ms, sort+
shard 0.4s→0ms. Net on real AOSP, regenerate+write: **add ~0.76s, remove ~0.80s,
property edit ~1.64s** (the worst case shown is editing `framework-minus-apex-defaults`,
the defaults for the entire framework jar; a leaf edit is sub-second). The property
edit's residual ~1.64s is intrinsic — reparse the large `Android.bp`, regenerate the
framework jar's analysis (~1.1s, serial), rewrite the ~18 shards that changed — not
overhead.

(I also tried parallelizing the targeted generate, to overlap a central edit's few
heavy modules; it shaved the edit to ~1.27s but **crashed on a filegroup edit** — that
edit grows the affected set dynamically across dependency edges, so a dependent could
race a still-regenerating dependency. The worklist's topological ordering is only safe
serially without the cold build's pause/resume, so I reverted it. The corpus caught
this; without it the racy version would have shipped.)

That edit was also made *deterministically* byte-identical. The earlier
consumer-regeneration fix (chapter 53) relied on the re-parse property hash flagging
a `java_defaults`'s consumers as "changed"; that hash is non-deterministic for some
modules, so the consumers were re-mutated (and picked up the edited defaults) only
~2 runs in 3. The fix generalizes chapter 53's "Fix 4": a dependency tag can declare
`PropagatesPropertyChanges()` — Soong's `DefaultsDepTag` does — and the warm
re-mutation expands the changed set to the transitive reverse-dep closure over those
tags, so every defaults consumer re-mutates for sure, independent of the hash. The
closure follows only propagating edges, so it stays the defaults-consumer set, not
the whole reverse-dep graph.

**A gap this same corpus found, recorded honestly:** the fix above covers the
*mutate-time* defaults propagation. The *generate-time* propagation — a consumer that
reads a dependency's output (a `filegroup`'s srcs) at GenerateBuildActions, picked up
via `interfaceChanged` — still rides the tolerant provider hash, which skips func-valued
providers and is non-deterministic for the same framework modules. So a filegroup-srcs
edit (reordering `framework-non-updatable-sources`) leaves ~6 consumer shards stale: not
byte-identical. It is the same soundness hole, one layer down, and it needs the same
medicine (a deterministic, total provider hash, or the content-addressed-query redesign
where there is no separate warm path to keep faithful). Until then the warm path is
trustworthy for property / defaults / direct / add / remove edits but not for
filegroup-srcs edits — which is exactly the kind of thing the byte-verification corpus
exists to keep honest.

## 59. File-scoped reparse

The daemon reparses only the `.bp` files that changed, not the whole tree. On
each warm build it lists the current `.bp` set, content-hashes each file against
the snapshot from the previous build, and reparses only the files whose hash
differs (plus any with no snapshot entry). `DiffParsedModules` then runs over just
those files; a deleted file is caught because its now-missing path fails to hash
and its modules go unmatched, which forces a correct fallback.

On a real frameworks/base edit this reparses 12 of 14,003 files in ~0.4 s,
against ~4 s to reparse the whole tree, and the regenerated manifest is
byte-identical to cold.

The remaining cost in this step is the content-hash scan itself -- reading the
~14k files to find which changed. Driving the scan from inotify/fanotify would
make even that O(edit).

## 60. Caching the soong_ui outer work

~7-8s of every warm build is the outer driver: Kati dumpvars, packaging, bootstrap.ninja regen, glob check.

Fixes:

* Cache dumpvars by `.mk` file hash (saves ~2.5s).
* Make packaging a no-op when nothing relevant changed (saves ~1-2s).
* Cache bootstrap.ninja regen by Soong-source hash (saves ~2-3s).
* Use inotify to defer glob checks (saves ~1s).

Effort: ~days per piece; aggregate weeks.

After this: the soong_ui floor drops from ~7-8s to <1s. The remaining warm floors are the soong analysis itself (~4.4s, already O(edit)) and the stock-ninja manifest reload (~5.1s, chapter 33).

## 61. Per-module action cache, fully enabled

Soong has a `buildActionsCache` behind the flag `--incremental-build-actions`. It hashes each module's resolved inputs (properties + dependency provider hashes), looks up the hash, and reuses cached ninja text if found.

It is currently underused. Enabling it by default and making it robust would mean: when the changed module's GenerateBuildActions produces identical output to its cached version (very common), even the changed module's emit is a cache hit.

For "I made a comment change in a `.bp`" edits — common during real iteration — this should make Soong's analysis itself a sub-100ms operation.

Effort: weeks of validating the cache and closing edge cases.

## 62. The pure-function invariant by construction

Every clean fix has been an instance of this invariant:

> *A module's build actions, and a singleton's output, should be a pure, content-addressed function of the resolved graph.*

* **Pure**: no hidden state, no order dependence, no clock/env reads not declared.
* **Content-addressed**: identifiers (rule names, dedup names, variable names, output paths) are hashes of identity, not visitation-order counters.
* **Function of resolved graph**: every consumer of a value is also a pure function of its inputs, all the way down.

The retrofit work I did is enforcing pieces of this invariant in Soong after the fact. The strategic work is enforcing it by construction — i.e., rewriting Soong's analysis on top of a pure-query engine.

This is what the standalone engine demonstrates. Making it the real Soong backend is the strangler-fig migration (Section 66).

### A small proof sketch

Let me make the invariant operational, because the central claim of this whole document rests on it.

**Claim.** If every module's build actions are a pure function `f(resolved_inputs)` of (its content hash + its dependencies' provider hashes), and every singleton's output is a pure fold `g({per_module_contributions})` over the live module set, then the warm build's ninja manifest is bit-identical to a cold build's manifest for the same source tree.

**Proof sketch.** The resolved graph for a given source tree is uniquely determined: the .bp files define modules, the mutators (themselves pure functions of properties) split them into variants, defaults are merged, dep edges are resolved. Two cold runs on the same tree produce the same resolved graph.

Now consider a warm edit that changes a single module M from input X to input Y. Every other module's resolved input is unchanged. By purity of `f`, every other module's `f(input)` is unchanged. So every other module's emitted ninja bytes are unchanged. Module M's `f(Y)` differs from cold's `f(X)` only at module M.

For modules that *read* M's exported provider, their resolved input changes only if M's provider changed. By purity again: if M's exported provider hash equals cold's, no consumer's input changed and no consumer's ninja text changed. If M's provider changed, the *direct* consumers' inputs changed; their `f` runs again; their outputs may or may not change. The propagation continues *exactly* as far as the chain of interface changes reaches and no further.

For singletons: each singleton's output is `g({c_i for module i in live set})`. Cold and warm see the same live set, except possibly M's contribution `c_M` differs. So `g_cold = g({c_1, ..., c_M_cold, ...})` and `g_warm = g({c_1, ..., c_M_warm, ...})`. They are equal iff `c_M_cold = c_M_warm`. The corpus's `comment` and `reorder` edits don't change any singleton contribution (the API surface, the install paths, the license metadata are all unchanged). The `dropsrc` edit changes only the contributing module's srcs (likewise irrelevant to singletons). The `addmod` edit adds a new contribution `c_{M+1}` to every singleton — which is exactly why addmod needs incremental singletons to be warm-correct.

This is what the byte-corpus empirically confirms. Three of the four edit kinds (comment, reorder, dropsrc) leave singletons untouched and pass byte-equality. The fourth (addmod) modifies singletons and falls back to cold. The invariant *predicts* this exact split before you run the test. —

The proof is informal but the structure is real: any analyzer that respects this invariant *cannot* produce a wrong incremental result. It can only produce a slow one (cache miss). This is the structural promise that distinguishes Bazel/Buck2/Nix from Soong, and the structural promise the kernel-leveraged redesign (Part X.5) buys for Soong without the rule-rewrite cost.

## 63. Remote analysis cache

Once analysis is a pure function of the resolved graph, its outputs are *portable*. The Ninja text emitted for `framework-core` given inputs X is the same regardless of which workstation produces it.

This unlocks a **remote analysis cache**: a service that stores module-input-hash — ninja-text mappings. Engineers hit the cache before running analysis. CI populates it. On a fresh workstation, you don't analyze — you fetch.

Bazel has this (the remote action cache, extended to analysis). Buck2 has this. Soong doesn't, today. Adding it would change the new-machine experience dramatically: a fresh sync could in principle build framework in minutes instead of hours.

The engineering: ~weeks for a basic version, more to integrate with Google's internal RBE infrastructure.

## 64. Content-addressed action cache (Bazel/Buck2 style)

The analog of the analysis cache, but at the action level. When the build is about to run `javac` on inputs X, look up the (rule, inputs) hash in a content-addressed action cache. If hit, fetch the outputs directly. If miss, run the command and store the result.

This is the secret sauce of Bazel/Buck2's "absurdly fast on a fresh checkout." Some of Soong's actions go through Google's RBE (Remote Build Execution) infrastructure, but the integration isn't as deep or as default-on as Bazel's.

Wiring this in fully — every action sandboxed, every action's inputs declared, every action's outputs hash-stored — is a multi-year project. The reward is enormous.

## 65. Sandboxed, hermetic actions

For caching to be sound, actions must be hermetic: their declared inputs cover everything they read; nothing else is accessible. Bazel runs every action in a sandbox.

Soong runs *some* actions in `sbox` (a sandbox wrapper). The coverage is partial. Extending it to all actions is a multi-month, careful project. Without hermeticity, content-addressed action cache risks correctness bugs (you cache a result whose hash didn't reflect a hidden input).

## 66. The strangler-fig migration

The biggest design move: gradually replace Soong's analysis with the pure-query engine, one module type at a time.

Pick the first module type. Probably `genrule` (real ninja output, low complexity, high frequency). Re-express its `GenerateBuildActions` as queries in the engine. Run both Soong's and the engine's outputs for every `genrule` in the tree. Byte-compare. When they're byte-identical for every real `genrule`, route the build through the engine for `genrule` and remove Soong's implementation.

Pick the next type. `filegroup`. Same process.

Pick the next. `cc_object`. Same process. Then `cc_library_static`. Then `java_library` (the big one). Then progressively the long tail.

Effort: years. But each step ships a real win (one more module type incrementally cached / sandboxed / remote-cacheable). The byte gate is the safety net throughout.

This is the same approach Roboleaf took (in spirit), and the same approach Google has used for other massive migrations (Borg — Borg2, Stubby — gRPC). It works, when you stay disciplined about the byte gate.

## 66a. Why not just use Buck2?

A reasonable question to ask, given how much I've praised Buck2 and DICE: if Buck2 already solved this, why not just adopt Buck2?

Three reasons. None of them is "Buck2 is technically worse" — Buck2 is genuinely the cleanest design in production. The reasons are all about the cost-benefit of moving a system the size of AOSP onto it.

**First, the rules problem is identical.** Buck2's incremental engine (DICE) is brilliant, but DICE doesn't know what `cc_library_shared` is. The Android-specific rule semantics — how variants are constructed, how APEX membership is handled, how the SDK boundary works, how `prebuilt_*` selection interacts with namespacing — all have to be re-expressed as Buck2 rules in Starlark. That is the same enormous long-tail engineering project Roboleaf hit when trying to re-express Soong's logic in Bazel. The engine is the small part of any build system; the rule layer is where the years of accumulated wisdom live. Switching from "rewrite for Bazel" to "rewrite for Buck2" doesn't change the scope.

**Second, Buck2's ecosystem at AOSP scale is unproven.** Buck2 is Meta's tool, optimized for Meta's monorepo and Meta's CI infrastructure. It is excellent at the workloads Meta runs — large Rust, Python, and Hack codebases with a particular variant model. AOSP's workload is different: deeper variant cross-product, harder cross-language interop (Java/Kotlin/C++/Rust/Python in the same build), tighter integration with kernel build artifacts, much more aggressive use of code generation (AIDL, HIDL, protobuf, aconfig). The Buck2 team have not tuned Buck2 for these workloads at scale, and a migration would require finding out which corners need work in real time. That is a research project on top of an engineering one.

**Third, the strategic risk profile is wrong.** Adopting another company's flagship build infrastructure for Google's flagship operating system creates a permanent dependency on Meta's roadmap. Meta is friendly today; Meta is responsive to upstream contributors; that can change. Soong is Google's own; the Android build team controls the release schedule, the deprecation policy, the security posture. Roboleaf's path (Bazel, also Google's) at least kept the dependency in-house. Buck2 would put the critical infrastructure of every Android release in a position where the other team gets to decide when a breaking change ships.

So: Buck2 is the right *shape* for what AOSP needs, but it is not the right *thing* to bet on, because the value Buck2 brings is mostly in its engine, and the work that has to happen for AOSP is mostly in the rule layer. The kernel-leveraged redesign in Part X.5 takes Buck2's *idea* (pure-query engine, content-addressing, demand-driven evaluation with early cutoff) and reimplements it in the Soong codebase, where the existing rule code can be kept verbatim via wrap-don't-rewrite. You get DICE's incrementality story without buying Meta's whole ecosystem and without Roboleaf's rule-rewrite cost. That is the asymmetry I am betting on.

Stated differently: copying the *invariant* is cheap; copying the *implementation* is expensive. The invariant is well-documented in Buck2's papers, Salsa's design, the rust-analyzer architecture docs, and Adapton's original work. The implementation is a multi-year team commitment to someone else's product. Take the invariant; build your own implementation in the context that needs it.

## 67. Persistent javac/metalava daemons

For the Java side. Each `javac` invocation pays ~1-2s of JVM startup + JIT warmup before doing actual work. Metalava is worse.

The fix: persistent worker processes. Ninja has a "pool" feature; Bazel has built-in "worker" support; Buck2 has "persistent workers" first-class. Wire up javac and metalava as workers. Avoid forking per compile.

Effort: weeks. Wins on Java edits are dramatic — `javac` invocations on small library edits drop from ~5s to ~1s.

## 68. RBE plus distributed analysis: even cold builds get fast

The endgame. If analysis is cacheable, distributed, and remote, then "cold" builds — the dreaded fresh-machine experience — become fast too. New engineer checks out the tree; first build pulls almost everything from the remote cache; their machine compiles only the deltas they actually changed.

This is the Bazel-internal experience at Google for many large projects: even cold builds finish in minutes because almost all work is cached.

AOSP could in principle get here. The path is everything above: hermetic actions — content-addressed action cache — remote action cache — remote analysis cache.

This is the multi-year strategic bet.

---

# Part X.5 — A kernel-leveraged redesign (the version I would actually build)

The proposed designs in chapters 58-68 are a menu of mostly-independent improvements. They are each individually correct, and pursuing any subset of them advances the cause. But there is a stronger statement available: a *single* unified design that wraps the existing module-type code, leans on the Linux kernel for the parts the kernel is already better at than any userland reimplementation could be, and reduces "incremental analysis" from a hard custom problem to a standard pattern. This chapter is that design. It is the version I would actually build if I were starting fresh and the goal were millisecond inner loops on real AOSP.

The argument has four parts. First, where the Linux kernel already solved problems Soong is currently solving badly. Second, what disappears by construction when you adopt the kernel's idioms. Third, the migration trick that avoids the "multi-year project" framing. Fourth, the whole stack, top to bottom.

## 69. Where the Linux kernel actually helps

The kernel has spent thirty years solving "track changes to a huge mutable state efficiently." Steal it wholesale.

**`fanotify` / `inotify` kills the residual content-hash scan.** The daemon already reparses only the changed `.bp` files (file-scoped reparse, ~0.4s), but to find which files changed it still content-hashes the whole ~14k-file `.bp` set against the previous snapshot every build. Subscribe to changes instead: the build daemon watches every `Android.bp` (and every `.mk`, every source file in scope) and the kernel tells you, with the precision of "this exact path was written at this exact moment," which files changed since the last build. There is no scan. There is no walk. The cost of "what changed" drops from O(tree size) to O(changes), which on a real inner loop is literally one file or two. The Linux page cache and the kernel's `dnotify`/`inotify`/`fanotify` family have been tuned for exactly this workload for decades; the current content-hash scan is doing by hand what the kernel does for free.

**`overlayfs` or `btrfs` copy-on-write gives you free snapshots of the source tree.** Each build references a snapshot. Comparison between builds is O(changed files), not O(tree size). The snapshot mechanism is in the kernel; the userland tool is one syscall. No bespoke versioning. No content-hash store of source files. The filesystem already does it.

**The page cache model is the right mental model for module storage.** Keep a hot working set in memory; evict cold entries; persistence lives on disk. Soong currently treats memory as ground truth, which is why daemon restarts are catastrophically expensive: kill the resident process, lose every analysis result, restart from cold. The kernel's model says: in-memory is a cache; the on-disk content-addressed store is the truth. Restarts are cheap, because the cache reheats lazily as queries demand it.

**`RCU` (read-copy-update) is the right concurrency model for the module graph.** Readers — the parallel `GenerateBuildActions` calls — see a stable snapshot of the module graph. A writer publishes a new version atomically. No locks. No torn reads. No "did this property get mutated mid-pass." The Linux kernel relies on RCU for its own dentry cache and inode tables, which face the same "millions of readers, occasional writer" workload as a build's module graph. Soong's current mix of mutex-and-channel synchronization is a worse version of the same pattern.

**`systemd`-style socket activation: the build daemon can be killed and restarted freely.** Because its state is on-disk content-addressed, the cache survives. The first query after a restart pays a one-time fetch from disk; everything else is hot. Today's Soong resident process is precious because killing it loses every memoized result; the kernel-style design makes the daemon disposable.

Each of these is a thirty-year-mature idiom in the Linux ecosystem. None of them is a research project. Each one corresponds to a thing Soong is currently doing the hard way.

## 70. What dies, by construction

Adopt those idioms and a long list of current Soong pain points stops existing.

**Mutators go away.** Variant derivation becomes a pure query: "give me module `framework-core` for `arch=arm64, sdk=current, apex=com.android.foo`" returns a memoized result computed on demand. There is no global pass. There is no question "did mutator N see module Z." The expensive whole-graph machinery of the current Soong mutator pipeline is replaced by lazy, demand-driven evaluation of exactly the variants any consumer needs.

**Singletons go away.** The license graph, `module-info`, `all-modules`, packaging — each becomes an incremental fold over the live module-contribution set. Think Differential Dataflow, or just a memoized reduce. Add a module: one new contribution gets folded in. Remove a module: one contribution gets folded out. The "singleton is single-use" bug from chapter 45 becomes structurally impossible because you are not calling a function with side effects — you are updating a relation.

**The destructive dedup rewrite goes away.** Dedup is a query over the final build-statement set: hash each order-only list, group by hash, emit phonies for groups with two or more members. Pure function. Recomputed every build for free because it is cheap. Fix 2 from chapter 51 — non-destructive, content-addressed dedup — was the band-aid version of this in the existing architecture. In the kernel-leveraged design, dedup is just a query result and there is no band-aid to apply.

**Position-shift problems go away.** The `# Defined:` comment is a derived field on the module, computed from the file's current state at write time. There is no cached separate-from-the-build-action piece of state that can go stale. Fix 6 from chapter 55 — the position-shift re-serialize — was, again, a band-aid for a problem the new design does not have.

**Faithfulness checks go away.** There is no separate warm path to verify against a cold baseline. Every query is the same query whether the cache is hot or cold; the only difference is wall-clock time. The corpus from chapter 49 is still useful as a regression net, but the *necessity* of the warm-vs-cold byte equality check vanishes because there is only one path.

That is six structural problems disappearing by construction. The fifty thousand lines of careful surgery the current Soong receives from the six fixes in Part IX — every one of them is implementing, after the fact, an invariant the kernel-leveraged design would have given for free.

## 71. The migration trick that avoids "multi-year project"

Section 66 (the strangler-fig migration) describes re-expressing every module type's `GenerateBuildActions` as queries as a years-long project. That framing assumes you *rewrite* each module type. You don't have to.

`GenerateBuildActions` is already nearly pure. It takes a resolved module and its dependency providers, emits ninja text, and sets its own providers. Treat the existing Go function as a sealed black box. Memoize it on a key of `(module_content_hash, sorted_dep_provider_hashes)`. If you ever call it with the same key again, return the cached ninja bytes without invoking the function at all. You have not touched a single module type's logic. You have changed *when and how often* it runs.

The interface is: `genActions(resolved_module, dep_providers) -> (ninja_bytes, exported_providers)`. The implementation: call the existing Go function once per unique key, cache the result, serve subsequent calls from the cache. Soong's existing `--incremental-build-actions` infrastructure is reaching for this; the difference is making it the default and the only path, and pairing it with the upstream pure-query graph so the cache key is reliably derivable.

The mutator pipeline *is* the part that needs replacing, because it is the global-pass machinery that violates the pure-function invariant. But mutators are uniform and small compared to the hundreds of module types: there are ~70 mutators, each typically a few hundred lines, each doing one thing. Rewriting ~70 mutators as on-demand queries is months, not years. And — this is the key — the per-module `GenerateBuildActions` logic stays exactly as-is, forever if you want.

So the actual scope of work is:

* Stand up the query engine (the standalone engine from chapter 56 is the prototype; harden it).
* Lean on the kernel for `fanotify` watch, `overlayfs` snapshots, RCU-style graph publication.
* Rewrite the mutator pipeline as ~70 pure queries (months).
* Wrap `GenerateBuildActions` and its callers in the cache layer (weeks).
* Re-express singletons as incremental folds (multi-month for the top five, as in chapter 58, but in the new architecture these are just queries with a folding combinator).
* Wire the engine into the resident server, `soong_ui`, and the ninja writer.

That is a year-or-two project for a small team, not the multi-year Roboleaf-scale project that "rewrite every rule" would be. And every step ships an incremental win: get the mutator pipeline ported, wins on cold-build analysis. Get the wrapper in, wins on warm-build analysis. Get the singleton folds in, addmod becomes warm.

## 72. The whole stack, top to bottom

Here is the full architecture, in the order data flows through it on every build.

**1. `fanotify` tells the daemon which `Android.bp` (and `.mk`, and source) files changed.** The kernel maintains the watch list; the daemon receives a delta stream. Zero work on unchanged files. Cost of "what changed" is O(actual changes).

**2. The parser produces a new `parsed_bp` object for each changed file; its content hash is compared against the cached one.** Files whose content hash is unchanged cost zero CPU beyond the hash. Files whose hash changed produce a new `parsed_bp` value, which becomes input to downstream queries.

**3. Module resolution is a query: `resolve(bp_hash) -> module_set`.** Memoized. Inputs: the parsed bp's hash and any cross-file references it touches. Output: the set of declared modules. If the changed bp's content didn't actually change the declared modules' identity (a comment-only edit), this query returns the same output and downstream queries don't fire.

**4. Variant derivation is a query: `variants(module, axes) -> variant_set`.** Memoized. Lazy. Variants for an arch nobody asks for never get computed. The arch mutator's job is now spread across two functions: the variant-axes table (a static description of what axes exist) and the per-module-variant resolver (a pure function of the module and the axis selection). Mutator dies.

**5. Provider computation is a query: `providers(variant, dep_providers) -> providers`.** Memoized on the variant's content hash plus its dependencies' provider hashes. Salsa-style early cutoff: if a dep's providers re-compute to the same hash, this query doesn't fire.

**6. `GenerateBuildActions` is a query wrapping the existing Go code.** Same interface as before; cached on `(module_content_hash, sorted_dep_provider_hashes)`. The Go function is called only on actual misses. On a typical warm edit, almost all calls are cache hits.

**7. Singletons are incremental folds over the module-contribution relation.** Each singleton has a per-module contribution function and a combiner. `module-info` is sort-and-concat. `all-modules` is set-union. License-graph is graph-merge plus transitive closure (the only non-trivial fold). On a membership change, one contribution gets folded in or out; the singleton's output recomputes; downstream queries that consume it see the change.

**8. Manifest writing is a delta-write.** A shard is rewritten if and only if any of its build statements' hashes changed. The existing `wasRegenerated` machinery from chapter 54 does this already; in the new design it falls out of the query graph for free, because each shard's content is itself a query whose inputs are the per-module build action queries.

**9. The on-disk store is content-addressed and survives daemon restarts.** Cache keys are hashes; values are bytes. The store is just a directory of `<hash> -> <value>` files (or a simple LevelDB-style key-value store). Restarts cost nothing because the disk is the truth and memory is a cache.

Every step is content-addressed. Every step has the property that if its inputs haven't changed, neither has its output, and you can prove that without running anything. The kernel handles the "what files changed" question. The query graph handles the "what derivations changed" question. The on-disk content-addressed store handles "what artifacts exist."

This is what Nix figured out for package builds, what Bazel figured out for huge monorepos, what Salsa figured out for IDE incrementality, what `rust-analyzer` figured out for live code analysis. None of it is new. What would be new for Soong is admitting that bolting incrementality onto a batch system was the wrong move, and that the clean fix is to invert the data flow so incrementality is the default and "batch" is just "the cache happens to be cold."

## 73. Honest caveats

A few places where this design is harder than the four chapters above make it sound.

**`fanotify` is not free at AOSP scale.** Watching ~14,000 `Android.bp` files (plus the source trees they reference) is a real number of kernel watch slots. Linux defaults will exhaust quickly. The fix is one `sysctl` plus a careful watch-coalescing scheme (watch the directory inodes, not every file inside them). The kernel will do this efficiently if you ask it correctly. It will do this badly if you treat it as "just subscribe to every file."

**Cache invalidation across the query graph still needs careful design.** Salsa, DICE, and Adapton have all had to solve corner cases (cycles, dynamic dependencies, time-based inputs). Most of these don't apply to a build system, but a few do (filesystem mtimes leaking in, environment variables, configuration flags). Each needs an explicit input edge.

**The on-disk store has to be GC'd.** Without a garbage collector, the content-addressed store grows monotonically. Nix's GC is a real piece of engineering; Bazel's action cache eviction is non-trivial; this design needs the same. Not a research problem, but real work.

**Wrapping `GenerateBuildActions` requires the existing Go to actually be pure.** Most of it is. Some isn't — a few module types do file I/O during `GenerateBuildActions`, read globals, or otherwise leak hidden inputs. Each instance needs to be either declared as an explicit input or refactored to be pure. This is ~weeks of audit work, not multi-year. But it has to happen before the cache is trustworthy.

**Mutator parity will surface bugs.** Even with a clean reimplementation, the mutator pipeline today does subtle things that the existing rule code depends on without saying so. The byte-corpus from chapter 49 is what catches these; expand it to cover every module type, run continuously during the migration. The same discipline Roboleaf applied — except now you're migrating *inside* one system, not between two.

None of these caveats invalidates the design. They are the real work of executing it.

## 74. Why this is not Roboleaf

It is fair to ask: if Roboleaf — a serious, well-funded migration to a more disciplined architecture — got wound down, why would a similar-spirit redesign succeed where it didn't?

Three differences.

**You don't rewrite the rules.** Roboleaf re-expressed every module type in Starlark. That was the long-tail work that ate years. The wrap-don't-rewrite approach keeps every `GenerateBuildActions` exactly as it is. The rule layer — which is where the AOSP-specific accumulated wisdom lives — is untouched.

**You don't fork the build.** Roboleaf maintained two parallel builds (Soong and Bazel) during the migration. Engineers had to keep both working. The kernel-leveraged design is an internal re-architecture of Soong itself; there is only one build path; the rule code is unchanged; the migration is transparent to feature teams.

**The scope is bounded.** Roboleaf's scope was "Bazel for everything." This design's scope is "the query engine and mutator pipeline." That is concretely on the order of 50,000 lines of new code plus ~30,000 lines of refactored Soong runtime, vs Roboleaf's order-of-magnitude-larger surface. A bounded scope ships.

That said: I am not pitching this as risk-free. It is real work. The point is that it is the *right* shape of work — bounded, structured, ships in pieces, with the rule layer untouched — and that the technical foundation (kernel primitives + content-addressed query graph + wrap-not-rewrite) is sound enough to absorb the inevitable surprises along the way.

If I were starting today, this is what I would build.

---

# Part XI — How other build systems do it

For perspective, deep-dive on the alternatives.

## 69. Make

Already covered. The progenitor. Imperative, file-based, manual dependency tracking, recursive-make broken, slow to parse at scale. Still everywhere in small-to-medium projects.

## 70. Bazel and Starlark

Bazel is Google's open-sourced version of internal Blaze. It is the closest competitor to Soong philosophically and the model Roboleaf tried to migrate AOSP to.

**Build files** are written in Starlark, a deliberately restricted Python subset. Starlark forbids:

* File I/O.
* Mutation of globals after initialization.
* Importing arbitrary Python modules.
* `eval`, `exec`, reflection.

This is restrictive on purpose. Starlark code is deterministic, sandboxable, and analyzable. You can hash a Starlark function's behavior given its inputs because nothing else is observable.

**Rules** are written in Starlark. A rule has:

* A name.
* A set of attributes (typed properties).
* A `implementation` function that, given the inputs, declares the actions to run and the providers to expose.

The implementation function returns *action descriptions*: "to produce these outputs, run this command with these inputs." Bazel then runs the actions; their results feed back into other rules.

**Providers** are typed Python objects (Starlark objects) attached to a build target, exposing its outputs to dependents. Same idea as Soong providers, but in a stricter language.

**Actions** are content-addressed. Bazel hashes the inputs, the command line, the toolchain configuration. The hash is the action's identity. Outputs are stored keyed by hash. Re-running the same action with the same inputs is a cache hit, locally or remotely.

**Sandboxing.** Each action runs in a sandbox that exposes only the declared inputs. If the action tries to read something undeclared, it fails. This catches missing-dep bugs at action time, not at runtime.

**Remote caching.** The action cache can be remote — a server shared across a team or CI pool. First builder of a (rule, inputs) hash populates the cache; everyone else fetches.

**Remote execution.** Actions can also be executed remotely (on a fleet). The local machine becomes a coordinator; the heavy compile work happens on the cluster.

**Analysis caching.** Bazel's analysis phase is itself memoized: target — provider mapping is cached as long as the inputs to that target's rule haven't changed. This is what makes Bazel's no-op builds finish in seconds even on huge trees.

**Variants.** Bazel uses `select()`, a much more constrained mechanism than Soong's multi-axis variants. select() can branch on configuration flags but cannot create arbitrary cross-product variants. This is one of Roboleaf's biggest stumbling blocks: bridging Soong's variant model to Bazel's was a substantial project.

What Bazel got right: discipline. Restrict the rule language, make actions hermetic, make caching automatic. The result is correctness and speed.

What Bazel paid for: enormous migration costs for existing codebases. Re-expressing Soong's logic in Starlark is hundreds of thousands of LoC of careful work.

## 71. Buck2 and DICE

Buck2 (Meta, open-sourced 2023, written in Rust, after ~2 years of internal development) takes Bazel's ideas further. Its core, **DICE** (Demand-driven Incremental Computation Engine — *not* "dependency injection"; that's a different concept entirely), is a pure memoized query engine in the Salsa / Adapton tradition (the same family that powers rust-analyzer).

**Every derivation is a pure function.** From inputs (other queries) to outputs.

**Query dependency tracking.** Automatic. When query A reads query B, the engine records "A depends on B." When B's output changes, A is invalidated. When B's output is recomputed and *unchanged* (early cutoff), A is *not* invalidated.

**Salsa-style early cutoff.** This is the key. If you edit a comment in a Java file, downstream queries that depend on the file's contents may be re-evaluated, but they may find that the comment didn't affect *their* computed output (the parsed AST is unchanged after stripping comments, say). They produce the same output hash; their downstream consumers don't re-evaluate.

Buck2 builds are extraordinarily fast on near-no-op changes. A trivial edit can finish in tens of milliseconds, end to end.

What Buck2 got right: the engine itself. The Rust implementation is fast and the query model is the cleanest in the industry.

What Buck2 paid for: Buck2 inherits Bazel's rule discipline issues; rules are still complex to write; ecosystem integration is still a project.

## 72. Nix

Nix takes "everything is hash-addressed" to its logical extreme. Every build artifact is a function of all its inputs, including the *compiler version*. Caching is automatic and exact.

Nix's language (Nix expression language) is functional, lazy, and pure. Each derivation declares its inputs (other derivations, source files), its build command, and its outputs. The hash of all inputs uniquely identifies the output.

What Nix got right: hermeticity by construction. The Nix store is content-addressed; nothing leaks in or out.

What Nix paid for: the language is unfamiliar. Existing build systems don't translate to Nix without substantial reengineering.

## 73. Shake

Shake is a Haskell library for writing build systems. Build rules are monadic Haskell functions. Shake handles incremental computation, caching, parallel execution.

Shake's strength is expressiveness: you can write build rules that do arbitrary computation in Haskell, with full type safety and pure functions, and Shake automatically tracks dependencies.

It hasn't scaled to massive trees in practice; it's used mostly for medium-sized projects (GHC's own build system is Shake).

## 74. Tup

Tup uses ptrace (or equivalent) to *auto-detect* dependencies by observing what files an action reads at run time. The build description doesn't declare deps; Tup discovers them.

Beautiful idea. Hasn't scaled to giant trees (ptrace overhead, complexity of handling all edge cases).

## 75. Pants

Pants is a Python-focused build system that's gained traction in some companies (Twitter, Toolchain). It uses a pure-query engine similar in spirit to Buck2's DICE.

## 76. Gradle

Mentioned earlier. Build tool for Android apps. Has its own incremental engine, daemon, caching system. Powerful and complex. Not used to build the AOSP platform itself, but every Android app developer encounters it daily.

---

# Part XII — Roboleaf: the Bazel-for-Android attempt

## 77. What Roboleaf was

In approximately 2020, Google began a major project to migrate the AOSP build to Bazel. The project was called **Roboleaf** internally. A real team — substantial engineering investment over several years — was on it.

The goal: replace Soong with Bazel as the analyzer. Keep Ninja as the executor (Bazel can drive Ninja, though it doesn't by default). The pitch: get all of Bazel's benefits (hermeticity, remote caching, remote execution, Starlark discipline) for AOSP.

## 78. What it shipped

Roboleaf shipped real artifacts. At its 2022 peak, the `build/bazel/` directory in AOSP contained over a hundred thousand lines of Starlark — a parallel rules implementation covering most of the major Soong module types. The key pieces:

* **`build/bazel/`** — the new rules library. A Bazel rule for `cc_library_shared`, one for `cc_library_static`, one for `java_library`, and so on for several dozen of the most common module types. Each rule had to faithfully reproduce its Soong counterpart's behavior down to per-attribute defaulting and per-variant configuration.
* **`bp2build`** — an auto-converter that read `Android.bp` files and emitted Bazel `BUILD` files. Coverage hit roughly 60% of modules end-to-end. The remaining 40% — variants, defaults expansion, SDK members, APEX-bound libraries, anything with substantial mutator interaction — were either hand-converted, partially handled, or left unconverted.
* **`mixed_build`** — a working hybrid mode where Bazel and Soong each handled different parts of one AOSP build, gluing their outputs together as intermediate ninja artifacts. Some modules were "Bazel modules"; the rest stayed Soong; the build tool drove both.
* **A bp2build test harness** that compared Bazel's output against Soong's for converted modules, looking for behavioral divergence.

For a period, you could build selected parts of Android via either Soong or Bazel. The infrastructure was real, it worked, and the people building it were serious engineers who had thought about it for years.

## 79. What stalled it

Roboleaf was effectively wound down across 2023 and 2024. The `build/bazel/` directory was removed from AOSP in early 2024 — itself a quiet bombshell for anyone tracking the project, since it represented thousands of engineering days of work being deleted. Public communications about *why* were mostly silent, but the contours come into focus from a few sources.

**The long tail had longer teeth than anyone budgeted for.** The first 60% of module types — filegroups, simple libraries, basic binaries — converted relatively cleanly. The remaining 40% included the modules that *every actual Android release depends on*: APEX, dexpreopt, the SDK-snapshot machinery, sysprop, vintf, the boot image, the system image. Each had Android-specific subtleties that required months of careful Starlark engineering. By 2022 the team was visibly grinding on the long tail with no clear end date.

**Variants were the central technical headache.** Bazel's `select()` mechanism is much more constrained than Soong's variant system. To bridge the gap, Roboleaf leaned on Bazel "transitions" — a feature for creating per-target configuration changes — but transitions have their own performance cost in Bazel's analysis phase, and using them at AOSP's scale (tens of thousands of variants) hit limits the Bazel team had not anticipated. Specific modules like `apex_aconfig_library` and the SDK-snapshot members became multi-quarter projects to model correctly.

**Singletons demanded a Bazel-side rewrite.** Soong's `module-info`, license-graph, and packaging singletons aren't expressible directly in Bazel. The team built parallel Bazel-side aggregator targets to reproduce them, but the architectures didn't match, and edge cases that worked transparently in Soong (a license attached to a module that's reachable only through a defaults chain, say) required hand-tuning in Bazel.

**Performance reality clashed with the pitch.** The original case for Roboleaf was, in significant part, "Bazel is faster." On real cold builds of converted subgraphs, Bazel's analysis phase was sometimes *slower* than Soong's — its rules had to be more conservative than Soong's hand-tuned mutators, and the cache hit-rate story required a warmup period that engineers in the inner loop never reached. Bazel's remote action cache would have delivered the win on warm builds, but the integration with Google's RBE infrastructure was its own project. The visible-to-engineers speed delta on common edits was unclear or negative.

**Dual maintenance was the silent killer.** While Roboleaf was active, every team had to keep its modules building on *both* Soong and Bazel. The bp2build converter helped, but the long-tail modules required manual `BUILD` files in parallel with `Android.bp`. Every refactor took twice as long. Every new feature had to ship twice. Feature teams complained.

**Tooling parity took its own years.** Engineers' daily tools — `m`, `mma`, `lunch`, IDE integration with Android Studio, `repo` integration — were all built around Soong. Bringing them to Bazel parity was a separate engineering track that competed with the rules work for headcount.

**The decisive moment, by my read of public signals**, was 2023 Q4 when Google's build org reorganized and Roboleaf no longer had its own dedicated headcount line. The team didn't fail to ship — they were redirected. Several of the engineers went to Google's internal Bazel team, where they now work on features that benefit AOSP by other means: tighter Starlark performance, RBE integration with Soong directly, faster bzlmod resolution. The strategic intent (Bazel discipline for AOSP) didn't go away; the specific path of "replace Soong with Bazel" did.

The honest reading: Roboleaf was a *correct* strategic direction. Bazel's discipline IS the right model. But the migration cost — for an existing system as deeply integrated as AOSP, with as long a tail of edge cases, against a competing track of "incrementally improve Soong" that was delivering visible wins — was higher than the company chose to absorb. It was wound down not because it was wrong but because the cost-benefit curve sat too far in the future.

There's a humbling lesson in this for anyone (including me) proposing to "rewrite Soong's analysis on top of a pure-query engine." See Section 66 again. The same forces apply. The right move is strangler-fig, not grand-replacement.

## 80. What we learned

Several useful lessons for anyone proposing another migration:

* **The byte-equality gate is non-negotiable.** Roboleaf's byte-comparison framework was the right tool; many migrations don't have one and pay for it.
* **Tooling parity must come early.** If `m` and IDE integration don't work, engineers won't adopt the new path no matter what.
* **The long tail has long teeth.** Plan for 30% of the modules to take 70% of the work. Budget accordingly.
* **The migration's payoff structure is back-loaded.** The big wins (hermetic caching, distributed execution) only kick in after migration is complete or nearly so. Plan for a long period of dual maintenance with no visible payoff.
* **Strategic clarity matters.** What is the migration *for*? If it's for caching, just bolt caching onto the existing analyzer. If it's for variant elegance, rewrite the variant machinery in place. Migrating "because the other system is fundamentally better" is a less-grounded argument than "we need feature X and migration delivers it cleanly."

Same lessons apply to the engine approach in Part X.66. The strangler-fig migration of Soong to a pure-query engine *is* the technically correct direction, but it should not be undertaken lightly, and it should be driven by concrete, near-term deliverables.

---

# Part XIII — Strategic synthesis

## 81. The pure-function invariant, one more time

If I had to compress everything I've learned about this work into one sentence:

> A module's build actions, and a singleton's output, should be a pure, content-addressed function of the resolved graph.

Every clean fix I have made is an instance. Every clean redesign would be a wholesale embrace. Bazel's discipline, Buck2's DICE, Nix's content-addressing — all are implementations of this invariant from different angles.

Soong violates the invariant in many places. Mutators are imperative graph transformations. GenerateBuildActions is arbitrary Go. Singletons are stateful. The six tactical fixes are each a retroactive enforcement of one corner. The standalone engine is what enforcing the invariant by construction looks like.

## 82. Tactical vs strategic

Two valid approaches. They serve different needs.

**Tactical**: patch Soong. Surgically enforce the pure-function invariant in each subsystem of Soong as needed. Ship wins one at a time, gated by the byte corpus. The six fixes are this. They make real `m frameworks/base` faster on common edits TODAY.

The cost: tactical patches accumulate. Every new subsystem with a state problem requires a new surgery. Singletons need a surgery. The reparse floor needs a surgery. soong_ui needs a surgery. Each is its own piece of work. Total cost over time is significant.

**Strategic**: re-architect. Replace Soong's analysis with a pure-query engine. The engine is committed; turning it into the real backend is years of work — expressing each module type, mutator, and singleton in the new model. The end state has no whack-a-mole; every problem is solved by construction.

Both are valid. The pragmatic answer is to do both: bank the tactical wins now (committed) while investing in the strategic re-architecture as a long-term durable bet (strangler-fig, one module type at a time). The tactical work earns engineering time back day to day; the strategic work eventually ends the whack-a-mole.

What you do NOT want to do is rely solely on tactical patches and hope they keep up. Each generation of edit types reveals a new gap. At some point the architectural work becomes the only honest path forward.

## 83. Where I would invest if it were my money

Here is the priority list I would commit budget to, in order, with the case for each.

**1. soong_ui floor caching.** ~2-3 weeks of work, saves 7-8 seconds off every warm build. This is the highest-ROI fix available. Kati dumpvars, Kati packaging, bootstrap.ninja regen, and the glob check together account for more than half of every warm build's wall time, and *none* of that work is doing anything meaningful in the inner loop. Hash the relevant input files, cache the output, skip the run on a hit. The fix is mechanical; the code change is contained to `build/soong/ui/build/`; the risk is low because the worst-case failure mode is "cache miss, falls back to current behavior." Do this first because it pays for itself within a single inner-loop iteration.

**2. inotify-driven change detection.** ~3-4 weeks. The resident daemon already does file-scoped reparse: it content-hashes the `.bp` set against the previous build's snapshot and reparses only the changed files (12 of 14,003 on a real frameworks/base edit, ~0.4s instead of ~4s for a whole-tree reparse). The remaining cost in that step is the content-hash scan itself — reading the ~14k files to find which changed. Driving the scan from inotify/fanotify makes even that O(edit).

**3. Per-module action cache, default-on.** ~2 weeks plus validation. Soong already has `--incremental-build-actions`; the work is making it robust and on-by-default. After this, the changed module's own `GenerateBuildActions` is a cache hit on common edits, dropping Soong-side analysis from 100ms to <10ms. Combined with #1, the soong-side analysis stays well under a second; the remaining warm wall is dumpvars and the ninja reload.

**4. Incremental singletons (top 5).** ~2-3 months for the canonical five (`module-info`, `all-modules`, `raw-files`, `license-graph`, `packaging`). Bigger investment than the above but unlocks `addmod`/`removemod` warm. This is the last common edit category not yet covered. License-graph is the riskiest piece because of transitive closure; the other four are simple folds. Worth doing because without it, "add a new module" remains a cold-rebuild trigger forever.

**5. Persistent javac + metalava daemons.** ~3-4 weeks each, saves 20-90 seconds per framework Java edit. Different cost regime than `.bp` edits — this is what makes framework engineers' lives better. The prototypes exist (`metalava-daemon` is real); the integration into Soong as a persistent worker is the work. Done well, framework iteration loops change from "minutes" to "seconds."

**6. Strangler-fig migration to the kernel-leveraged engine.** This is the strategic bet, on the order of 1-2 years for a small team. Stand up the query engine, port the mutator pipeline to queries, wrap `GenerateBuildActions` in the cache layer, port singletons to incremental folds, wire fanotify in for change detection. Pick one module type at a time for the strangler-fig, byte-verify against current Soong, ship in pieces. Each piece is its own win; the cumulative effect is that incrementality becomes structural rather than retrofitted. Make this the platform for the next decade of AOSP builds.

**7. Content-addressed action cache with remote caching.** ~2-3 years to land fully, the Bazel-equivalent payoff. After #6 is in flight and the analysis side is content-addressed, extend the discipline to actions: hash inputs, store outputs in a remote cache, fetch on hit. This is what makes cold builds on fresh checkouts finish in minutes instead of hours. Requires sandboxing (#65) for soundness, which is the actual long pole. The bet that pays the largest dividend, but only after the foundations from #1-6 are in.

Items 1-5 are tractable side-projects of a single experienced engineer; together they get the inner loop to a couple of seconds (the soong analysis is already ~4.4s and O(edit); the remaining floors are dumpvars and the ninja reload). Items 6 and 7 are team-scale commitments; together they get cold to "minutes on a fresh machine" and warm to "imperceptible." Neither set requires throwing out what's there. The work is patient and cumulative, not heroic.

The total expected impact, if all of this lands:

* Warm `.bp` edit: ~50 ms end-to-end (down from current ~17.8 seconds).
* Warm Java edit: ~1-2 seconds (down from current ~30+ seconds).
* Cold full build on a fresh machine with hot remote cache: ~minutes (down from current hours).

These numbers are not aspirational hand-waving. They are projections from the unit costs already measured plus the savings each fix delivers. Get to ms-overhead builds is real engineering, not magic.

---

# Glossary

**Adapton.** A general-purpose framework for incremental computation, developed academically (Hammer et al., ~2014). Pioneered the demand-driven, dynamic-dependency-tracking, early-cutoff model that Salsa, DICE, and rust-analyzer all descend from. Not used directly in production at scale, but its papers are the reference for how this style of engine works.

**action cache.** A content-addressed cache mapping (rule, inputs) hash — outputs. Bazel/Buck2 have strong versions; Soong's is weaker and behind a flag.

**dyndeps.** A Ninja feature for declaring extra dependencies that aren't known until after a command runs. The command emits a small ninja-formatted file declaring "I also depend on these inputs and produced these outputs"; Ninja reads it and augments the DAG.

**Android.bp.** The declarative module description file Soong reads. Replaces Android.mk.

**Android.mk.** The legacy Make-based module description file. Mostly gone.

**APEX.** A self-contained, signed package containing platform code that can be updated separately from the OS image. APEX modules have their own variants.

**Bazel.** Google's open-source build system. Uses Starlark for rules. Strong incremental and caching support. Migration cost to Bazel for existing codebases is high.

**bp2build.** A Roboleaf-era tool that auto-converted `Android.bp` files to Bazel `BUILD` files. Handled about 60% of modules end-to-end; the long tail required hand-conversion. Removed from AOSP in early 2024 along with the rest of `build/bazel/`.

**Blueprint.** The Go library Soong is built on. Provides parsing, module registration, mutator scheduling.

**buildDef.** Soong's in-memory representation of one ninja `build` edge.

**build graph / DAG.** The directed acyclic graph of dependencies the build system manages.

**Buck2.** Meta's Rust build system. Uses DICE, a pure-query incremental engine. Currently the cleanest design in production.

**cold build.** A build from scratch, no resident state, no caches.

**content-addressing.** Naming a thing by a hash of its content rather than position or sequence. Stable across invocations.

**CreateModule.** Soong API for a module/mutator to spawn new modules at runtime.

**d8.** The dex compiler. Turns JVM bytecode into Android's DEX format.

**dedup.** Soong's mechanism for replacing shared order-only dep lists with a named phony target. Now non-destructive.

**defaults.** A Soong mechanism for sharing properties between modules.

**depfile.** A side-channel file emitted by a compiler listing the files it actually read. Ninja uses depfiles to fill in transitive header dependencies.

**dexpreopt.** Ahead-of-time compilation of Java bytecode to native code, run during the build for installed packages.

**DICE.** Buck2's incremental computation engine. Pure memoized queries with early cutoff.

**dyndeps.** Ninja feature for declaring dependencies not known until after a command runs.

**faithfulness.** Whether a warm build's result equals a cold build's result for the same inputs.

**filegroup.** A Soong module type that's "just a named bundle of source files."

**GenerateBuildActions.** The per-module function that emits ninja text. Written in arbitrary Go.

**genrule.** A Soong module type running a generic command.

**header jar.** A stripped-down jar containing only public API signatures. Used as a compile-time dependency to enable compile avoidance.

**hermetic.** A build action is hermetic if its declared inputs cover everything it reads.

**incremental analysis.** Re-running analysis on only what changed since the last build.

**incremental build.** Re-running execution on only what changed since the last build.

**Kati.** Google's faster Make implementation. Used in the AOSP build for product config and a thin packaging layer.

**license-graph.** A Soong singleton that walks every module's license metadata and emits the transitive closure.

**manifest.** The Ninja file (or sharded set) describing all build edges.

**metalava.** The SDK API stub generator and signature checker. Slow. ~298 invocations per cold AOSP build.

**mixed_build.** Roboleaf's hybrid mode where Bazel and Soong each handled different parts of a single AOSP build, gluing their outputs together as intermediate ninja artifacts. Worked, but doubled maintenance for every team. Removed in early 2024 with the rest of the Roboleaf infrastructure.

**module.** A logical unit producing some artifact (jar, .so, .apk, etc.). The first-class noun in Soong.

**module type.** The kind of module: `java_library`, `cc_library`, etc.

**Mutator.** A Go function running over the module graph that may transform it. Whole-graph. Soong has ~100.

**Ninja.** The build executor AOSP uses. Reads a manifest, runs commands in dep order, in parallel.

**phony.** A Ninja built-in rule that doesn't run a command; just groups outputs into an alias target. `build all: phony out/hello out/foo` means "to build `all`, make sure `out/hello` and `out/foo` exist; the command for `all` itself is nothing."

**restat.** A Ninja rule annotation (`restat = 1`) that tells Ninja "the output of this rule might be unchanged after the command runs." After execution, Ninja stats the output; if its mtime didn't advance, downstream edges are not invalidated. Lets "regenerate ninja file" steps avoid cascading rebuilds when the file came out identical.

**subninja.** A Ninja directive that pastes a separate `.ninja` file into the manifest as if its contents were inlined here, with its own variable scope. AOSP uses ~200 of these to shard the manifest across files Soong can write in parallel.

**pristineProperties.** The post-mutate, pre-generate snapshot of a module's properties. Used for faithfulness comparison.

**provider.** A typed message a module exposes to its dependents.

**R8.** The code shrinker / optimizer / obfuscator for Java.

**Salsa.** A Rust framework for demand-driven, memoized, on-demand incremental computation. Powers `rust-analyzer`. The cleanest small implementation of the Adapton/Buck2-style query engine.

**Skyframe.** Bazel's internal evaluation engine. Memoized, demand-driven, lazy. Similar in spirit to Salsa/DICE, but predates both and is implemented in Java. The thing inside Bazel that makes incremental analysis work.

**regeneratedModules.** The set of modules whose GenerateBuildActions ran in this build (dirty + interface-propagated).

**resident.** A long-lived Soong process that keeps the resolved module graph in memory across builds.

**restat.** Ninja annotation that the output may be unchanged after the command runs.

**Roboleaf.** Google's project to migrate AOSP to Bazel. Effectively wound down.

**shard.** One of ~200 partial files the AOSP ninja manifest is split into.

**Singleton.** A Soong handler that runs once over the whole module set, aggregating contributions.

**Soong.** Android's build analyzer. Written in Go. Reads Android.bp, writes Ninja.

**Starlark.** Bazel's restricted DSL for rule definitions. Sandboxed and cacheable.

**strangler-fig.** Migration pattern where you build new functionality alongside old and gradually replace.

**Turbine.** The header-jar generator. Faster than full javac.

**variant.** A specific combination of attributes (arch, os, sdk, apex, ...) that a Soong module can produce. One declaration can produce dozens of variants.

**warm build.** An incremental build that reuses cached / resident state.

**worker process.** A long-lived helper process the build executor talks to via RPC, instead of forking a new process per action. Avoids JVM startup overhead for tools like javac, metalava, R8. Bazel calls this "persistent workers"; Buck2 calls it the same. Soong does not have a first-class story for this yet.

---

---

# Coda. The patient is breathing.

I want to close where I started: with the picture of the dependency graph.

A build is a graph of work to be done, with edges describing what must happen before what. That is true for `gcc hello.c`, where the graph has four nodes and three edges. It is true for the AOSP build, where the graph has tens of millions of edges and produces a phone. It is true for every build system ever written. The job has never changed. The graph has always been the thing.

What has changed, over fifty years, is the strategy we use to manage the graph. Stuart Feldman, in 1976, gave us the idea that the *user* describes the graph and the *system* schedules the work. Evan Martin, in 2010, gave us the idea that the description and the scheduling can be separated, the description outsourced to a configuration tool, the scheduling kept small and fast. Google, with Bazel, gave us the idea that the description itself can be sandboxed and content-addressed, so the system can cache work across machines and across years. Meta, with Buck2 and DICE, gave us the idea that *every* derivation can be a pure memoized function, with the engine tracking dependencies automatically, with early cutoff making no-op work disappear. The Linux kernel, all the while, was solving the underlying "what changed" problem on a different time axis: page caches, inotify, RCU, copy-on-write filesystems, all of it tuned for "track mutations in a giant mutable state efficiently."

Each generation of build system has been a different answer to the same question: *how do you not do work you don't have to do?* The answers have gotten more rigorous over time, and they have gotten more useful — modern Bazel builds, with hot remote caches, return in seconds on changes that twenty years ago would have taken hours.

Soong, the system this document is mostly about, is somewhere in the middle of that progression. It is much better than the Android.mk world it replaced. It is not as rigorous as Bazel or Buck2. It is what you would build, in fact, if you had to migrate a giant existing imperative codebase to declarative form without breaking everything in motion. It works. It also has a tax: every place the declarative model has imperative leaks — mutators, singletons, accumulated state — is a place where the system has to be careful, and where the people maintaining the system have to know things that aren't written down.

What I have spent the last while doing is enforcing the invariants that the declarative model implies, retroactively, in the corners of Soong that violate them. Six fixes. A byte-equality gate. A small clean-slate engine alongside, as proof of what the architecture *should* look like. The work is not glamorous. It is the kind of work that consists of staring at a debug trace for two days and writing ten lines of code on the third. It is also, I think, the kind of work that quietly compounds: every fix removes a class of future bugs, every invariant enforced shortens the surface area where the next person has to be careful.

If I have done my job in this document, you now know what a build is, how the modern ones work, where AOSP's specifically gets stuck, and what the path out looks like. You also know — and this is the part that matters most to me — that none of it is mysterious. The build problem is a graph problem. The graph problem has good solutions. The solutions have been published in papers, implemented in production at other companies, embedded in the Linux kernel. There is no magic. Just patience and the willingness to find out which assumptions are wrong.

Build systems are infrastructure. Infrastructure rewards the people who pay attention to it. Make slowed down a hundred teams; Soong saved them; the next generation of analyzer — whichever it is, whoever builds it — will save the next hundred. The work is humble. The payoff, in engineering hours redeemed across an organization the size of Android, is enormous.

The patient is breathing. The right kind of stubborn refusal to wave the hard parts away gets it walking. After that, the rest is just engineering.

*End of document.*
