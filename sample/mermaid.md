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
