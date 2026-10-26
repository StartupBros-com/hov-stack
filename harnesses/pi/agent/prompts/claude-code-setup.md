---
description: Guided Claude Code setup and optimization with codebase analysis and artifact creation
argument-hint: Optional goal (e.g., "optimize AGENTS.md", "create agent for X", "full setup")
---

# Claude Code Setup

You are helping a developer set up and optimize Claude Code for their project. Research shows optimized instruction files improve accuracy 5-11%. House doctrine: AGENTS.md carries the content and the CLAUDE.md beside it is a one-line `@AGENTS.md` pointer (Claude Code 2.1.277+ reads AGENTS.md by itself only when no CLAUDE.md is on the path, so the pointer stays and every nested AGENTS.md needs one). Follow a systematic approach: audit existing setup, understand needs, design artifacts, then implement.

## Core Principles

- **Audit before acting**: Understand what Claude Code artifacts already exist
- **Ask clarifying questions**: Identify ambiguities before designing
- **Hierarchical awareness**: AGENTS.md/CLAUDE.md files inherit from parents - don't duplicate
- **Use file-based todos (todos/ + /skill:file-todos)**: Track all progress throughout

---

## Phase 1: Discovery

**Goal**: Understand what the user wants to accomplish

Initial request: $ARGUMENTS

**Actions**:
1. Create todo list with all phases
2. Categorize the request:
   - **Instruction-file (AGENTS.md) optimization** → Launch claude-md-analyzer
   - **Create new artifact** → Launch claude-artifact-designer
   - **Full project setup** → Audit + recommendations + implementation
   - **Audit only** → Analysis without changes
3. If unclear, ask user what problem they're solving
4. Summarize understanding and confirm

---

## Phase 2: Setup Audit

**Goal**: Understand existing Claude Code configuration

**Actions** (do this directly, don't spawn an agent):
1. Glob for existing artifacts:
   - `~/.claude/agents/*.md` - global agents
   - `~/.claude/commands/*.md` - global commands
   - `~/.claude/skills/**/skill.md` - global skills
   - `.claude/agents/*.md`, `.claude/commands/*.md` - project-specific
   - `**/AGENTS.md`, `**/CLAUDE.md` - all instruction files in the hierarchy (CLAUDE.md should be an `@AGENTS.md` pointer; a non-pointer twin or a nested AGENTS.md with no pointer is drift)

2. Read key files to understand current state

3. Present summary:
   - What artifacts exist (agents, commands, skills)
   - Instruction-file hierarchy (AGENTS.md + pointers) with approximate sizes
   - Any obvious issues (duplication, bloat >5KB, file trees)

---

## Phase 3: Clarifying Questions

**Goal**: Fill in gaps before designing

**CRITICAL**: DO NOT SKIP. Ask before designing.

**Actions**:
1. Based on intent and audit, identify unknowns:
   - For AGENTS.md: What content at which level? Any protected areas?
   - For agents: What triggers it? What tools? Model tier?
   - For commands: What workflow? Arguments needed?
2. **Present questions and wait for answers**

If user says "whatever you think is best", provide recommendation and get confirmation.

---

## Phase 4: Artifact Design

**Goal**: Design the Claude Code artifact(s)

**Actions**:

### For instruction-file optimization:
1. Launch claude-md-analyzer agent on target directory
2. Present the generated AGENTS.md (plus the one-line `@AGENTS.md` CLAUDE.md pointer) with rationale
3. **Ask user to approve or request changes**

### For new Agent/Command/Skill:
1. Launch claude-artifact-designer agent with requirements
2. Present design with trade-offs
3. **Ask user to approve or request changes**

---

## Phase 5: Implementation

**Goal**: Create the artifact(s)

**DO NOT START WITHOUT USER APPROVAL**

**Actions**:
1. Wait for explicit approval
2. Create files in appropriate locations:
   - Global → `~/.claude/`
   - Project-specific → `.claude/`
3. Update todos as you progress

---

## Phase 6: Summary

**Goal**: Document what was accomplished

**Actions**:
1. Mark all todos complete
2. Summarize: what was created, key decisions, file paths, how to use, next steps
