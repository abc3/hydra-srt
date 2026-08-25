[
  checks: [source_paths: ["lib"]],
  layers: [
    core: "HydraSrt.*",
    web: "HydraSrtWeb.*"
  ],
  deps: [
    forbidden: [
      # `HydraSrt.Application.config_change/3` is the OTP callback Phoenix's own
      # generator writes, and its whole body is the hand-off to the endpoint so a
      # config reload reaches it. Removing the call would silently break endpoint
      # reconfiguration on a release upgrade, so the seam is declared here rather
      # than deleted or baselined. It is the only core-to-web edge in the tree.
      {:core, :web, except_edges: [{"HydraSrt.Application", "HydraSrtWeb.Endpoint"}]}
    ]
  ],
  calls: [
    forbidden: [
      # Network and API input must not create atoms from untrusted strings.
      {"HydraSrt.*", ["String.to_atom"]}
    ]
  ],
  smells: [
    # These five modules are MCP tool handlers. `definitions/0`, `handles?/1`, and
    # `call/2` form an intentional private dispatch contract, while each module
    # remains separate for its tool domain. A shared behaviour would document the
    # contract but would not consolidate the domain-specific implementations.
    behaviour_candidate: [
      ignore: [
        modules: [
          "HydraSrt.Mcp.Tools.Destinations",
          "HydraSrt.Mcp.Tools.Interfaces",
          "HydraSrt.Mcp.Tools.Logs",
          "HydraSrt.Mcp.Tools.Nodes",
          "HydraSrt.Mcp.Tools.Tags"
        ]
      ]
    ]
  ]
]
