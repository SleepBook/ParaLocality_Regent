import "regent"

local PageRankConfig = require("pagerank_config")

local c = regentlib.c

fspace Page {
  num_outlinks : uint32;
  rank         : double;
  next_rank    : double;
}

fspace Link(r : region(Page)) {
  src_page : ptr(Page, r);
  dst_page : ptr(Page, r);
}

terra skip_header(f : &c.FILE)
  var x : uint64, y : uint64
  c.fscanf(f, "%llu\n%llu\n", &x, &y)
end

terra read_ids(f : &c.FILE, page_ids : &uint32)
  return c.fscanf(f, "%d %d\n", &page_ids[0], &page_ids[1]) == 2
end


task initialize_graph(r_pages   : region(Page),
                      r_links   : region(Link(r_pages)),
                      damp      : double,
                      num_pages : uint64,
                      filename  : int8[512])
where
  reads writes(r_pages, r_links)
do
  var ts_start = c.legion_get_current_time_in_micros()
  for page in r_pages do
    page.rank = 1.0 / num_pages
    page.next_rank = (1.0 - damp) / num_pages
    page.num_outlinks = 0
  end

  var f = c.fopen(filename, "rb")
  skip_header(f)
  var page_ids : uint32[2]
  for link in r_links do
    regentlib.assert(read_ids(f, page_ids), "Less data that it should be")
    var src_page = unsafe_cast(ptr(Page, r_pages), page_ids[0])
    var dst_page = unsafe_cast(ptr(Page, r_pages), page_ids[1])
    link.src_page = src_page
    link.dst_page = dst_page
    src_page.num_outlinks += 1
  end
  c.fclose(f)
  var ts_stop = c.legion_get_current_time_in_micros()
  c.printf("Graph initialization took %.4f sec\n", (ts_stop - ts_start) * 1e-6)
end


task rank_page(r_pages : region(Page),
               r_links     : region(Link(r_pages)),
               damp        : double)
where
  reads(r_links.{src_page, dst_page}),
  reads(r_pages.{rank, num_outlinks}),
  reads writes(r_pages.next_rank)
do
  for link in r_links do
    link.dst_page.next_rank +=
      damp * link.src_page.rank / link.src_page.num_outlinks
  end
end


task update_rank(r_pages     : region(Page),
                             damp        : double,
                             num_pages   : uint64)
where
  reads writes(r_pages.{rank, next_rank})
do
  var sum_error : double = 0.0
  for page in r_pages do
    var diff = page.rank - page.next_rank
    sum_error += diff * diff
    page.rank = page.next_rank
    page.next_rank = (1.0 - damp) / num_pages
  end
  return sum_error
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
  c.printf("* Max # Iterations : %11d *\n",   config.max_iterations)
  c.printf("**********************************\n")
  var r_pages = region(ispace(ptr, config.num_pages), Page)
  var r_links = region(ispace(ptr, config.num_links), Link( wild))
  --new(ptr(Page, r_pages), config.num_pages)
  --new(ptr(Link(r_pages), r_links), config.num_links)

  initialize_graph(r_pages, r_links, config.damp, config.num_pages, config.input)

-- TODO modify the partitioning of the graph --- what is the best partitioning you can
-- find?  Don't change the number of partitions, just how the graph is partitioned.
-- You only need to modify the following 3 lines of code.
  var num_iterations = 0
  var converged = false
  var ts_start = c.legion_get_current_time_in_micros()
  while not converged do
    num_iterations += 1
    var sum_error = 0.0
    rank_page(r_pages, r_links, config.damp)
    var res = update_rank(r_pages, config.damp, config.num_pages)
    converged = res <= config.error_bound*config.error_bound or num_iterations >= config.max_iterations
  end
  var ts_stop = c.legion_get_current_time_in_micros()
  c.printf("PageRank converged after %d iterations in %.4f sec\n",
    num_iterations, (ts_stop - ts_start) * 1e-6)
  if config.dump_output then dump_ranks(r_pages, config.output) end
end
regentlib.start(toplevel)
