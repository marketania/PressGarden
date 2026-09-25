# AI-assisted development

This repository uses GPT-6 as a **development workflow default**. The PressGarden application itself does not require OpenAI, an API key, or network access to OpenAI at runtime.

## Default model

Project-local Codex configuration selects:

```toml
model = "gpt-6-astra"
model_reasoning_effort = "medium"
```

Project defaults use top-level `model` and `model_reasoning_effort`; `[models.new_thread]` belongs to administrator-managed `requirements.toml`, not project configuration.

Codex loads project `.codex/config.toml` only for trusted projects, and explicit user/CLI choices can override project defaults.

## Model routing

Use the model according to the risk and complexity of the development task:

| Work | Model | Starting effort |
|---|---|---|
| Normal repository engineering | `gpt-6-astra` | `medium` |
| Safety-critical mutation, transaction, targeting, updater, recovery, or release logic | `gpt-6-astra` | `high` |
| Exceptionally difficult unresolved safety/correctness work | `gpt-6-astra` | `xhigh`, after a representative medium/high attempt |
| Documentation, branding, small isolated test/docs changes | `gpt-6-sol` | `medium` |

Do not raise reasoning effort automatically for every task. Use representative results and the risk of the change.

Example one-off override:

```bash
codex -m gpt-6-astra -c 'model_reasoning_effort="high"'
```

For a low-risk documentation task:

```bash
codex -m gpt-6-sol -c 'model_reasoning_effort="medium"'
```

## Prompt and instruction policy

Give the agent a clear goal, constraints, and definition of done. Avoid forcing it to read a large fixed document set before every edit. `AGENTS.md` contains the persistent repository rules; task-specific prompts should add only the context needed for that change.

The model should:
- infer routine implementation details from repository context;
- keep changes inside the requested scope;
- use tools to inspect the current source of truth before editing;
- run tests appropriate to the risk and scope of the change;
- distinguish prepared, committed, pushed, merged, released, and deployed states;
- stop before destructive production operations unless they are separately authorized.

## Runtime OpenAI integrations

There is currently no intended runtime OpenAI dependency in this repository. If a future feature adds one, treat that as a separate architecture change. For GPT-6 reasoning with tools, OpenAI's current guidance is to use the Responses API. GPT-6 Astra does not support reasoning effort `none`, and reasoning-enabled requests must follow the model's supported-parameter rules.

## Evaluation before changing defaults

When changing the project model or reasoning default, compare representative repository tasks and record:
- task success and correctness;
- safety-boundary violations;
- human corrections required;
- applicable test/CI results;
- latency and token/cost data when available.

Do not change defaults based only on a single successful task.

## Official references

- GPT-6 model guidance: https://developers.openai.com/api/docs/guides/latest-model
- GPT-6 Astra: https://developers.openai.com/api/docs/models/gpt-6-astra
- Codex configuration: https://learn.chatgpt.com/docs/config-file/config-basic
- GPT-6 Astra prompt/skills guidance: https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra
