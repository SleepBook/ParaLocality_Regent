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
fspace Edge(r: region(Node)) 
{
  source_node : ptr(Node, r),
  dest_node: ptr(Node, r)
}

task main()
  var Num_Parts = 4
  var Num_Elements = 20

--
-- Both the node and edge regions are unstructured --- the
-- index space is an abstract "pointer".  Note unstructured
-- index spaces still have a maximum size.
--
  var nodes = region(ispace(ptr, Num_Elements), Node)
  var edges = region(ispace(ptr, Num_Elements), Edge(nodes))

--
-- initialize node with node id
--
  var id = 0
  for node in nodes do
    node.id = id
    id = id + 1
  end

--
-- Create a linked list of the nodes, with an edge from node i to node i + 1
--
  var node_id = 0
  for edge in edges do
    var src_node = dynamic_cast(ptr(Node, nodes), node_id)
    var dest_node = dynamic_cast(ptr(Node, nodes), node_id + 1)
    edge.source_node = src_node
    edge.dest_node = dest_node
    node_id = node_id + 1
  end
  
  for edge in edges do
    c.printf("Edge from node %d to %d\n", edge.source_node.id, edge.dest_node.id)
  end
end
  
regentlib.start(main)
