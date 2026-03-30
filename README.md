#Trio Analyzer

- This is an engine-first PR — the goal right now is methodology review, not UI polish                                                                                                                           
  - LocalPackages/TrioAnalyzer/ contains the full analysis engine; everything in Trio/Sources/Modules/Analysis/ is the integration layer                                                                             
  - Entry point: Settings → Settings Analysis → Analyze Settings                                                                                                                                                   
  - It reads from Core Data and live settings — no log file parsing, no CSV                                                                                                                                          
  - TrioAnalysisBridge.swift is the only file that touches Trio internals; everything else is the pure Swift package
