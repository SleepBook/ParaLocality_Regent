-- Partation by edges
import "regent"

-- Helper module to handle command line arguments
local PageRankConfig = require("pagerank_config")

local c = regentlib.c

fspace Page {
  num_outlinks : uint32;
  rank         : double;
  next_rank    : double;
}

fspace Link(r_src : region(Page), r_dst : region(Page)) {
  src_page : ptr(Page, r_src);
  dst_page : ptr(Page, r_dst);
}

fspace ErrSum{
    sum : double;
}


terra skip_header(f : &c.FILE)
  var x : uint64, y : uint64
  c.fscanf(f, "%llu\n%llu\n", &x, &y)
end

terra read_ids(f : &c.FILE, page_ids : &uint32)
  return c.fscanf(f, "%d %d\n", &page_ids[0], &page_ids[1]) == 2
end

task initialize_graph(r_pages   : region(Page),
                      r_links   : region(Link(r_pages, r_pages)),
                      damp      : double,
                      num_pages : uint64,
                      filename  : int8[512])
where
  reads writes(r_pages, r_links)
do
  var ts_start = c.legion_get_current_time_in_micros()
  for page in r_pages do
    page.rank = 1.0 / num_pages
    page.next_rank = (1.0 - damp)/num_pages
    page.num_outlinks = 0
  end

  var f = c.fopen(filename, "rb")
  skip_header(f)
  var page_ids : uint32[2]
  for link in r_links do
    regentlib.assert(read_ids(f, page_ids), "Less data that it should be")
    var src_page = dynamic_cast(ptr(Page, r_pages), page_ids[0])
    var dst_page = dynamic_cast(ptr(Page, r_pages), page_ids[1])
    link.src_page = src_page
    link.dst_page = dst_page
    src_page.num_outlinks += 1
  end
  c.fclose(f)
  var ts_stop = c.legion_get_current_time_in_micros()
  c.printf("Graph initialization took %.4f sec\n", (ts_stop - ts_start) * 1e-6)
end

--
-- TODO: Implement PageRank. You can use as many tasks as you want.
--
task rank_page(r_src_pages : region(Page),
               r_dst_pages : region(Page),
               r_links : region(Link(r_src_pages, r_dst_pages)),
               damp : double)
where
    reads(r_links.{src_page, dst_page}),
    reads(r_src_pages.{rank,num_outlinks}),
    reads writes(r_dst_pages.{next_rank})
do
    for link in r_links do
        link.dst_page.next_rank +=
            damp * link.src_page.rank / link.src_page.num_outlinks
    end
end

task update_rank(r_pages : region(Page),
		 pid: uint,
                 damp : double,
                 num_pages : uint64, 
	         res: region(ispace(int1d), ErrSum))
where
    reads writes(r_pages.{rank, next_rank}),
    writes(res.sum)
do
    var sum_error : double = 0.0
    for page in r_pages do
        sum_error += (page.rank - page.next_rank) * 
                     (page.rank - page.next_rank)
        page.rank = page.next_rank
        page.next_rank = (1.0 - damp)/num_pages
    end
    res[pid].sum = sum_error 
end

--terra sumError(res: region(ispace(int1d), ErrSum),
task sumError(res: region(ispace(int1d), ErrSum),
	       iter: uint)
where
	reads (res.sum)
do
	var sum:double  = 0.0
	for i=1, iter do
		sum = sum + res[i].sum
	end
	return sum
end
	

task dump_ranks(r_pages  : region(Page),
                filename : int8[512])
where
  reads(r_pages.rank)
do
  var f = c.fopen(filename, "w")
  for page in r_pages do c.fprintf(f, "%g\n", page.rank) end
  c.fclose(f)
end

task toplevel()
  var config : PageRankConfig
  config:initialize_from_command()
  c.printf("**********************************\n")
  c.printf("* PageRank                       *\n")
  c.printf("*                                *\n")
  c.printf("* Number of Pages  : %11lu *\n",  config.num_pages)
  c.printf("* Number of Links  : %11lu *\n",  config.num_links)
  c.printf("* Damping Factor   : %11.4f *\n", config.damp)
  c.printf("* Error Bound      : %11g *\n",   config.error_bound)
  c.printf("* Max # Iterations : %11u *\n",   config.max_iterations)
  c.printf("* # Parallel Tasks : %11u *\n",   config.parallelism)
  c.printf("**********************************\n")

  -- Create a region of pages
  var r_pages = region(ispace(ptr, config.num_pages), Page)
  --
  -- TODO: Create a region of links.
  --       It is your choice how you allocate the elements in this region.
  --
  var r_links = region(ispace(ptr, config.num_links), Link(wild, wild))

  --
  -- TODO: Create partitions for links and pages.
  --       You can use as many partitions as you want.
  --

  -- Initialize the page graph from a file
  initialize_graph(r_pages, r_links, config.damp, config.num_pages, config.input)

  var allcolors = ispace(int1d, config.parallelism)
  var sublinks = partition(equal, r_links, allcolors)
  var src_nodes = image(r_pages, sublinks, r_links.src_page)
  var dst_nodes = image(r_pages, sublinks, r_links.dst_page)

  var subpages = partition(equal, r_pages, allcolors)
  
  var res = region(ispace(int1d, config.parallelism), ErrSum)

  var num_iterations = 0
  var converged = false
  __fence(__execution, __block) -- This blocks to make sure we only time the pagerank computation
  var ts_start = c.legion_get_current_time_in_micros()
  while not converged do
    num_iterations += 1
    --
    for color in allcolors do
        rank_page(src_nodes[color], dst_nodes[color], sublinks[color], config.damp)
    end

    -- need a sync here(interesting, the sync happens excplicitly)
    for color in allcolors do
        -- how to express a tree-reduction?
        update_rank(subpages[color], color, config.damp, config.num_pages, res)
    end
    var err = sumError(res, config.parallelism)
    converged = (err <= config.error_bound * config.error_bound) or
                (num_iterations >= config.max_iterations)
  end
  __fence(__execution, __block) -- This blocks to make sure we only time the pagerank computation
  var ts_stop = c.legion_get_current_time_in_micros()
  c.printf("PageRank converged after %d iterations in %.4f sec\n",
    num_iterations, (ts_stop - ts_start) * 1e-6)

  if config.dump_output then dump_ranks(r_pages, config.output) end
end

regentlib.start(toplevel)
