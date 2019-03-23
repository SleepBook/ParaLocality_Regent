-- Copyright 2016 Stanford University
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

import "regent"

local c = regentlib.c

fspace Node 
{
  id: int64
}

--
-- A parameterized field space is a function, creating a 
-- different field space for each distinct argument.
--
fspace Edge(r: region(ispace(int1d), Node)) 
{
  source_node : int1d,
-- what the hell is this constructor
  dest_node: int1d(Node, r)
}

task main()
  var Num_Parts = 4
  var Num_Elements = 20

--
-- Both the node and edge regions are unstructured --- the
-- index space is an abstract "pointer".  Note unstructured
-- index spaces still have a maximum size.
--
  var nodes = region(ispace(int1d, Num_Elements), Node)
  var edges = region(ispace(int1d, Num_Elements), Edge(nodes))

--
-- initialize node with node id
--
  for i = 0, Num_Elements do
    nodes[i].id = i
  end

--
-- Create a linked list of the nodes, with an edge from node i to node i + 1
--
  for j = 0, Num_Elements - 1 do
    edges[j].source_node = [int1d](j)
    edges[j].dest_node   = dynamic_cast(int1d(Node, nodes), [int1d](j + 1))
  end
  
  for edge in edges do
    c.printf("Edge from node %d to %d\n", edge.source_node, edge.dest_node.id)
  end
end
  
regentlib.start(main)
