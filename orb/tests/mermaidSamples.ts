export const mermaidSamples: Record<string, string> = {
  flowchart: `flowchart LR
  A[Prompt] --> B{Needs tools?}
  B -- yes --> C[Run tool]
  C --> D[Observe result]
  D --> B
  B -- no --> E([Answer])`,
  sequence: `sequenceDiagram
  autonumber
  participant U as User
  participant O as Orb
  participant C as Core
  U->>O: Send message
  O->>C: POST /missions
  C-->>O: stream events
  Note over O,C: tokens arrive incrementally
  O-->>U: Render transcript`,
  class: `classDiagram
  class Mission {
    +String id
    +Status status
    +start()
    +cancel()
  }
  class Machine {
    +String host
    +int cpus
  }
  Mission "many" --> "1" Machine : runs on
  Mission <|-- CloudMission`,
  state: `stateDiagram-v2
  [*] --> Queued
  Queued --> Running : lease acquired
  Running --> Waiting : needs input
  Waiting --> Running : reply
  Running --> Done
  Running --> Failed
  Done --> [*]
  Failed --> [*]`,
  er: `erDiagram
  USER ||--o{ MISSION : starts
  MISSION ||--|{ EVENT : emits
  MISSION }o--|| MACHINE : "runs on"
  USER {
    string id PK
    string email
  }
  MISSION {
    string id PK
    string status
  }`,
  gantt: `gantt
  title Mermaid support
  dateFormat YYYY-MM-DD
  section Desktop
  Renderer service   :done,    r1, 2026-10-01, 3d
  MermaidBlock       :active,  r2, after r1, 4d
  Browser tests      :         r3, after r2, 2d
  section iOS
  WKWebView renderer :crit,    i1, after r2, 4d`,
  pie: `pie title Time spent
  "Layout" : 42
  "Theming" : 23
  "Tests" : 20
  "Review" : 15`,
  mindmap: `mindmap
  root((Orb))
    Desktop
      Transcript
      Composer
    iOS
      Dashboard
    Core
      Missions
      Machines`,
  wide: `flowchart LR
  ${Array.from({ length: 16 }, (_, i) => `N${i}[Step number ${i} with a long label] --> N${i + 1}`).join("\n  ")}`,
};
