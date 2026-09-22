# Mermaid

Diagrams in fenced `mermaid` blocks render to SVG, bundled and offline. They
follow the Dark / Light theme and re-render on every save.

## Flowchart

```mermaid
flowchart LR
  A[Edit the file] --> B{Saved?}
  B -- yes --> C[MDLive re-renders]
  B -- no --> A
  C --> D[Diagram updates]
```

## Sequence

```mermaid
sequenceDiagram
  participant E as Editor
  participant W as FileWatcher
  participant R as Renderer
  E->>W: write + rename
  W->>R: debounced change
  R-->>E: fresh preview
```

## State

```mermaid
stateDiagram-v2
  [*] --> Idle
  Idle --> Rendering: file changed
  Rendering --> Idle: done
  Rendering --> Error: bad diagram
  Error --> Idle: fixed
```

## Wide sequence

A diagram wider than the column keeps its natural size and scrolls sideways,
like a wide table. The "Fit width" button above it shrinks it to the column.

```mermaid
sequenceDiagram
    actor U as User
    participant CLI as cli.py
    participant S as session.py
    participant F as files.py
    participant C as conversation.py
    participant K as client.py
    participant API as Endpoint
    participant P as parser.py
    participant E as editor.py
    participant G as gitops.py
    participant FS as Target files
    U->>CLI: "In greet.py, change Hello to Hi..."
    CLI->>S: send_request(text)
    S->>F: files_block(selected)
    F->>FS: read each selected file (UTF-8)
    alt a selected file is missing or unreadable
        F-->>S: error
        S-->>U: "Cannot send: <path> ..." (nothing sent)
    else all readable
        F-->>S: files block
        S->>C: build(system prompt, files block, text)
        S->>K: stream(messages)
        K->>API: POST /chat/completions {model, messages, stream:true}
        API-->>K: data: {choices[0].delta.content}
        S->>P: parse(reply)
        S->>E: validate(root, selected, edits, errors)
        E->>G: is_clean(), head()
        E->>FS: write each file
        G-->>E: commit hash
        S-->>U: "Applied n file(s). Created commit <hash>."
    end
```

## Broken on purpose

A diagram that fails to parse shows the source with an error line above it
instead of a blank area:

```mermaid
flowchart LR
  A --> B
  this is not valid mermaid ((( )))
```

Ordinary code is untouched:

```python
print("still highlighted")
```
