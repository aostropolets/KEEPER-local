/*****************
This file relies on the set of codes specified in the codes.sql and on the cohort of patients that sits in the cohort table
variables: @dbo, @target for schemas, @cohort_definition_id for cohort id
In the original experiment, patient identifiers were also extracted, here skipped
******************/

-- presentation, all conditions on day 0. XXX: may change to only limited concept set
select distinct
                p.person_id, year_of_birth, datediff(year, birth_datetime, cohort_start_date) as age,
                case when gender_concept_id=8507 then 'Male' else 'Female' end as gender,
                cohort_start_date as day_0,
                -- this consutruction will be used throughout, concantinates multiple strings belonging to the same patient
                -- here, we do not put the day in the name as everything is day 0, in later queries we add day
                presentation = STUFF((
                              SELECT distinct '; ' + concept_name
                              FROM @dbo.condition_occurrence md
                              JOIN @dbo.concept cc on concept_id = md.condition_concept_id
                              WHERE co.person_id = md.person_id and co.condition_start_date = md.condition_start_date
                              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, ''),
                cohort_definition_id
into #presentation
from @target.cohort c
join @dbo.person p on p.person_id=c.subject_id
join @dbo.condition_occurrence co on co.person_id = p.person_id and cohort_start_date = condition_start_date
where cohort_definition_id = @cohort_definition_id
;


-- visits overlapping with the day 0
with visits as (
  select distinct vo.person_id,
                  datediff(day, visit_start_date, visit_end_date) as duration,
                  visit_start_date,
                  case
                    when visit_concept_id in (262, 9201, 9203) then 'ER/IP'
                    when visit_concept_id in (5083) then 'Phone'
                    when visit_concept_id in (9202, 581477) then 'OP'
                    when visit_concept_id in (38004238, 38004250) then 'Ambulatory radiology'
                    else null end                                 as visit_type,
                  cohort_definition_id
  from @target.cohort c
    join @dbo.visit_occurrence vo
  on vo.person_id = c.subject_id
  where (visit_start_date = cohort_start_date or (visit_start_date<cohort_start_date and visit_end_date>cohort_start_date))
    and cohort_definition_id = @cohort_definition_id
),
     visits2 as (
       select v.*,
              case
                when duration > 0 then concat(visit_type, ' (', duration, ' days)')
                else visit_type end as                                                              visit_detail,
              row_number() OVER (PARTITION BY person_id ORDER BY visit_start_date, visit_type desc) rn
       from visits v)
select distinct a.person_id,
                case
                  when b.person_id is not null then concat(a.visit_detail, '->', b.visit_detail)
                  else a.visit_detail end as visit_detail,
                a.cohort_definition_id
into #visit_context
from visits2 a
       left join visits2 b on a.person_id = b.person_id
  and b.rn = 2
where a.rn = 1;

-- comorbidties and symptoms within the prior year [-365;0)
-- this is a common query that is used everywhere later. we only modify the time frames and the tables
with comorbidties as (
  select distinct person_id,
                  cohort_definition_id,
                  concat(concept_name, ' (day ', datediff(day, cohort_start_date, condition_era_start_date),
                         ');') as concept_name
  from @target.cohort c
    join @dbo.condition_era co
  on co.person_id = c.subject_id
    and datediff(day, cohort_start_date, drug_era_start_date)<0
    and datediff(day, drug_era_start_date, cohort_start_date)<=365
    join @dbo.concept cc on cc.concept_id = condition_concept_id
  where cohort_definition_id = @cohort_definition_id
    and concept_id in (select concept_id from #Codesets where codeset_id='conditions')
)
select distinct person_id,
                prior_comorbidity = STUFF((
                                            select distinct '; ' + concept_name
                                            from comorbidties cc
                                            where c.person_id = cc.person_id
                                            FOR XML PATH (''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, ''),
                cohort_definition_id
into #comorbidities
from comorbidties c;

-- drugs within the prior year [-365;0). xxx: relies on drug_era
with drugs as (
  select distinct person_id,
                  cohort_definition_id,
                  concat(concept_name, ' (day ', datediff(day, cohort_start_date, drug_era_start_date), ', ',
                         datediff(day, drug_era_start_date, drug_era_end_date), ' days);') as concept_name
  from @target.cohort c
    join @dbo.drug_era co
  on co.person_id = c.subject_id
    and datediff(day, cohort_start_date, drug_era_start_date)<0
    and datediff(day, drug_era_start_date, cohort_start_date)<=365
    join @dbo.concept cc on cc.concept_id = drug_concept_id
  where cohort_definition_id = @cohort_definition_id
    and concept_id in (select concept_id from #Codesets where codeset_id='drugs')
)
select distinct person_id,
                prior_drug = STUFF((
                                     select distinct '; ' + concept_name
                                     from comorbidties cc
                                     where c.person_id = cc.person_id
                                     FOR XML PATH (''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, ''),
                cohort_definition_id
into #prior_drugs
from drugs c;

-- alternative diagnosis within the next 28 days. XXX: time choice is random, may depend on chronicity
with dx as (
  select distinct person_id,
                  cohort_definition_id,
                  concat(concept_name, ' (day ', datediff(day, cohort_start_date, condition_era_start_date),
                         ')') as concept_name
  from @target.cohort c
    join @dbo.condition_era co
  on co.person_id = c.subject_id
    and datediff(day, cohort_start_date, condition_era_start_date)<=28
    and datediff(day, condition_era_start_date, cohort_start_date)<=0
    join @dbo.concept cc on cc.concept_id = condition_concept_id
  where cohort_definition_id = @cohort_definition_id
    and concept_id in (select concept_id from #Codesets where codeset_id='alternative dx')
)
select distinct person_id,
                alt_dx = STUFF((
                                 select distinct '; ' + concept_name
                                 from comorbidties cc
                                 where c.person_id = cc.person_id
                                 FOR XML PATH (''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, ''),
                cohort_definition_id
into #alternative_dx
from dx c;

-- diagnostic procedures around the day 0 [-14;+14]
with procedures as (
  select distinct person_id,
                  cohort_definition_id,
                  concat(concept_name, ' (day ', datediff(day, cohort_start_date, procedure_date), ');') as concept_name
  from @target.cohort c
    left join @dbo.procedure_occurrence po
  on po.person_id = subject_id
    and datediff(day, cohort_start_date, procedure_date)<=14
    and datediff(day, procedure_date, cohort_start_date)<=14
    join @dbo.concept cc on cc.concept_id = procedure_concept_id
  where cohort_definition_id = @cohort_definition_id
    and concept_id in (select concept_id from #Codesets where codeset_id='dx procedures')
)
select distinct person_id,
                dx_procedure = STUFF((
                                       select distinct '; ' + concept_name
                                       from procedures cc
                                       where c.person_id = cc.person_id
                                       FOR XML PATH (''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, ''),
                cohort_definition_id
into #dx_procedures
from procedures c;

-- measurements around day 0 [-14;+14]. XXX: here relies on range.
with meas as (
  select distinct person_id,
                  cohort_definition_id,
                  concat(concept_name, ' (', case
                                               when value_as_number > range_high then 'abnormal, high'
                                               when value_as_number < range_low then 'abnormal, low'
                                               else 'normal' end, ', day ',
                         datediff(day, cohort_start_date, measurement_date), ');') as concept_name
-- For some measurements exact value is more useful. here, I exctract the value + source unit as sometimes the latter are not mapped
 -- concat (concept_name, ' (', concat(value_as_number,' ', unit_source_value), ', day ', datediff (day, cohort_start_date, measurement_date), ');') as concept_name
  from @target.cohort c
    join @dbo.measurement m
  on m.person_id = subject_id
    and datediff(day, cohort_start_date, measurement_date)<=14
    and datediff(day, measurement_date, cohort_start_date)<=14
    join @dbo.concept cc on cc.concept_id = measurement_concept_id
  where cohort_definition_id = @cohort_definition_id
    and concept_id in (select concept_id from #Codesets where codeset_id='measurements')
    -- select only those with results. xxx: for claims, remove this line
    and value_as_number is not null
)
select distinct person_id,
                measurement = STUFF((
                                      select distinct '; ' + concept_name
                                      from meas cc
                                      where c.person_id = cc.person_id
                                      FOR XML PATH (''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, ''),
                cohort_definition_id
into #measurements
from meas c;

-- drug treatment within the year [0;+365]. xxx: relies on drug_era
with drugs as (
  select distinct p.person_id,
                  cohort_definition_id,
                  concat(concept_name, ' (day ', datediff(day, cohort_start_date, drug_era_start_date), ', ',
                         datediff(day, drug_era_start_date, drug_era_end_date), ' days);') as concept_name
  from @target.cohort c
    join @dbo.person p
  on p.person_id=c.subject_id
    join @dbo.drug_era de on de.person_id = p.person_id and cohort_start_date = drug_era_start_date
    and datediff(day, cohort_start_date, drug_era_start_date)<=365
    and datediff(day, drug_era_start_date, cohort_start_date)<=0
    join @dbo.concept cc on cc.concept_id = drug_concept_id
  where cohort_definition_id = @cohort_definition_id
    and concept_id in (select concept_id from #Codesets where codeset_id='drugs')
)
select distinct person_id,
                subseq_drug = STUFF((
                                      select distinct '; ' + concept_name
                                      from drugs cc
                                      where c.person_id = cc.person_id
                                      FOR XML PATH (''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, ''),
                cohort_definition_id
into #drugs_subs
from drugs c;


-- treatment procedures [0;+14]
with procedures as (
  select distinct person_id,
                  cohort_definition_id,
                  concat(concept_name, ' (day ', datediff(day, cohort_start_date, procedure_date), ');') as concept_name
  from @target.cohort c
    join @dbo.procedure_occurrence po
  on po.person_id = subject_id
    and datediff(day, cohort_start_date, procedure_date)<=14
    and datediff(day, procedure_date, cohort_start_date)<=0
    join @dbo.concept cc on cc.concept_id = procedure_concept_id
  where cohort_definition_id = @cohort_definition_id
    and concept_id in (select concept_id from #Codesets where codeset_id='tx procedures')
)
select distinct person_id,
                tx_procedure = STUFF((
                                       select distinct '; ' + concept_name
                                       from procedures cc
                                       where c.person_id = cc.person_id
                                       FOR XML PATH (''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, ''),
                cohort_definition_id
into #tx_procedures
from procedures c;


-- specific treatment, if exists (any time, examples: appendectomy or dialysis)
with procedures as (
  select distinct person_id,
                  cohort_definition_id,
                  concat(concept_name, ' (day ', datediff(day, cohort_start_date, procedure_date), ');') as concept_name
  from @target.cohort c
    join @dbo.procedure_occurrence po
  on po.person_id = subject_id
    join @dbo.concept cc on cc.concept_id = procedure_concept_id
  where cohort_definition_id = @cohort_definition_id
    and concept_id in (select concept_id from #Codesets where codeset_id='specific tx')
)
select distinct person_id,
                specific_tx = STUFF((
                                      select distinct '; ' + concept_name
                                      from procedures cc
                                      where c.person_id = cc.person_id
                                      FOR XML PATH (''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, ''),
                cohort_definition_id
into #specific_tx
from procedures c;


-- complications within the next year (0;+365]. XXX: todo select only first occurrence
 with complications as (
 select distinct person_id,
                 cohort_definition_id,
                 concat(concept_name, ' (day ', datediff(day, cohort_start_date, condition_era_date), ');') as concept_name
 from @target.cohort c
   join @dbo.condition_era co
 on co.person_id = c.subject_id
   and datediff(day, cohort_start_date, condition_era_date)<=365
   and datediff(day, condition_era_date, cohort_start_date)<=0
   join @dbo.concept cc on cc.concept_id = condition_concept_id
 where cohort_definition_id = @cohort_definition_id
    and concept_id in (select concept_id from #Codesets where codeset_id='complications')
 )
 select distinct person_id,
                 complication = STUFF((
                                        select distinct '; ' + concept_name
                                        from comorbidties cc
                                        where c.person_id = cc.person_id
                                        FOR XML PATH (''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, ''),
                 cohort_definition_id
 into #complications
 from complications c;


-- final data frame
select distinct p.person_id,
                p.day_0,
                p.age,
                p.gender,
                p.presentation,
                v.visit_detail,
                c.prior_comorbidity,
                ds.prior_drug,
                d.dx_procedure,
                m.measurement,
                a.alt_dx,
                t.tx_procedure,
                st.specific_tx,
                dss.subseq_drug,
                comp.complication,
                p.cohort_definition_id
from #presentation p -- Demographics and presentation
       left join #visit_context v
         on v.person_id = p.person_id -- Visit on day 0
       left join #comorbidities c
         on c.person_id = p.person_id -- Prior conditions and symptoms and treatment
       left join #prior_drugs ds
         on ds.person_id = p.person_id -- Prior treatment [XXX: for now only drugs, add procedures later]
       left join #dx_procedures d
         on d.person_id = p.person_id -- Diagnostic procedures
       left join #measurements m
         on m.person_id = p.person_id -- Laboratory tests
       left join #alternative_dx a
         on a.person_id = p.person_id -- Competing diagnoses
       left join #tx_procedures t
         on t.person_id = p.person_id -- Treatment procedures and medications
       left join #specific_tx st on
         st.person_id = p.person_id -- If specific tx is specified, such as appendicitis
       left join #drugs_subs dss on
         dss.person_id = p.person_id -- Medications
       left join #complications comp on
         comp.person_id = p.person_id -- Complications
;



