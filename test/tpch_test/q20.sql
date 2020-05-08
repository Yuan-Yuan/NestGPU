-- select
--   ps_suppkey, ps_partkey
-- from
--   partsupp
-- where
--   ps_partkey in (
--     select
--       p_partkey
--     from
--       part
--     where
--       p_name like '%green%'
--   )
--   and ps_availqty > (
--     select
--       sum(l_quantity * 0.5)
--     from
--       lineitem
--     where
--       l_partkey = ps_partkey
--       and l_suppkey = ps_suppkey
--       and l_shipdate >= '1995-01-31'
--       and l_shipdate < '1996-01-31'
--   )
-- ;

select
  s_name,
  s_address
from
  supplier, nation
where
  s_suppkey in (
    select
      ps_suppkey
    from
      partsupp
    where
--      ps_partkey = 2532
      ps_partkey in (
        select
          p_partkey
        from
          part
        where
          p_name like '%green%'
      )
      and ps_availqty > (
        select
          0.5 * sum(l_quantity)
        from
          lineitem
        where
          l_partkey = ps_partkey
          and l_suppkey = ps_suppkey
          and l_shipdate >= '1995-01-31'
          and l_shipdate < '1996-01-31'
        )
  )
  and s_nationkey = n_nationkey
  and n_name = 'GERMANY'
-- order by
--   s_name
;

