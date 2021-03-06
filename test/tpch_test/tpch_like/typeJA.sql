-- Query (Type JA): TPC-H Q2 - No need for exaplanation. (Only avoid order by)
-- With this query we control the size of the outer table by changing p_size!

select
  s_acctbal,
  s_name,
  n_name,
  p_partkey,
  p_mfgr,
  s_address,
  s_phone,
  s_comment
from
  part,
  partsupp,
  supplier,
  nation,
  region
where
  p_partkey = ps_partkey
  and s_suppkey = ps_suppkey
  and p_size = 20
  and p_type like 'MEDIUM%'
  and s_nationkey = n_nationkey
  and n_regionkey = r_regionkey
  and r_name = 'ASIA'
  and ps_supplycost = (
    select
      min(ps_supplycost)
    from
      partsupp, supplier,
      nation, region
    where
       p_partkey = ps_partkey
       and s_suppkey = ps_suppkey
       and s_nationkey = n_nationkey
       and n_regionkey = r_regionkey
       and r_name = 'ASIA'
    )
;

--Check selectivity of outer table
-- SELECT p_partkey, p_mfgr
-- FROM PART
-- WHERE p_size = 20
--     and p_type like 'MEDIUM%'
-- );

--Experiment -> Servey a p_size and p_type. Scale factor { 0.5, 1, 2, 4, 8 }
