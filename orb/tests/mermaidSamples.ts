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
  tall: `sequenceDiagram\n  participant A as Client\n  participant B as Core\n  A->>B: request 1\n  B-->>A: response 1\n  A->>B: request 2\n  B-->>A: response 2\n  A->>B: request 3\n  B-->>A: response 3\n  A->>B: request 4\n  B-->>A: response 4\n  A->>B: request 5\n  B-->>A: response 5\n  A->>B: request 6\n  B-->>A: response 6\n  A->>B: request 7\n  B-->>A: response 7\n  A->>B: request 8\n  B-->>A: response 8\n  A->>B: request 9\n  B-->>A: response 9\n  A->>B: request 10\n  B-->>A: response 10\n  A->>B: request 11\n  B-->>A: response 11\n  A->>B: request 12\n  B-->>A: response 12\n  A->>B: request 13\n  B-->>A: response 13\n  A->>B: request 14\n  B-->>A: response 14\n  A->>B: request 15\n  B-->>A: response 15\n  A->>B: request 16\n  B-->>A: response 16\n  A->>B: request 17\n  B-->>A: response 17\n  A->>B: request 18\n  B-->>A: response 18\n  A->>B: request 19\n  B-->>A: response 19\n  A->>B: request 20\n  B-->>A: response 20\n  A->>B: request 21\n  B-->>A: response 21\n  A->>B: request 22\n  B-->>A: response 22\n  A->>B: request 23\n  B-->>A: response 23\n  A->>B: request 24\n  B-->>A: response 24\n  A->>B: request 25\n  B-->>A: response 25\n  A->>B: request 26\n  B-->>A: response 26\n  A->>B: request 27\n  B-->>A: response 27\n  A->>B: request 28\n  B-->>A: response 28\n  A->>B: request 29\n  B-->>A: response 29\n  A->>B: request 30\n  B-->>A: response 30\n`,
};
