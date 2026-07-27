-- Detailed 2026 Mayor's Action Plan reference seed.

INSERT INTO reference.pillar (pillar_id, pillar_name, pillar_lead, pillar_lead_name, summary, overview, sort_order)
VALUES
    (1, 'Enhancing Public Safety', 'Deputy Mayor, Public Safety', 'Samuel Johnson, Assistant Deputy Mayor (Acting)', 'Baltimore takes an all-of-the-above approach to public safety, holding violent offenders accountable while offering concrete pathways out of criminal activity to those willing to accept.', 'Baltimore takes an all-of-the-above approach to public safety, holding violent offenders accountable while offering concrete pathways out of criminal activity to those willing to accept. The Scott Administration will build on our successful public safety strategies by continuing to address the root causes of violence, removing firearms from our communities, investing in data-driven proven community violence intervention strategies, responding effectively and efficiently to emergencies, and ensuring accountability and trust across public safety systems.', 1),
    (2, 'Prioritizing Youth, Older Adults, and Vulnerable Communities', 'Deputy Mayor, Health and Human Services', 'Dr. Letitia Dzirasa, Deputy Mayor', 'The Scott Administration will prioritize youth, older adults, and diverse communities through workforce pipelines, mentorship, schools, recreation facilities, and supports that help legacy residents age in place.', 'The Scott Administration will prioritize youth, older adults, and diverse communities by investing in workforce pipelines, mentorship opportunities, schools, and recreation facilities; protecting the legacy residents who built our city and deserve to age in place; and delivering intentional investment to counter decades of intentional disinvestment.', 2),
    (3, 'Clean, Healthy, and Sustainable Communities', 'Deputy Mayor, Operations and Deputy Mayor, Health and Human Services', 'Khalil Zaied and Dr. Letitia Dzirasa, Deputy Mayors', 'Baltimore promotes clean, healthy, and sustainable communities by tackling environmental health disparities, improving quality of life, and advancing long-term sustainability.', 'Baltimore promotes clean, healthy, and sustainable communities by tackling environmental health disparities, improving quality of life, and advancing long-term sustainability for current and future generations. We are committed to clean streets, green spaces, and public health systems that meet the needs of our communities. Building a cleaner, healthier Baltimore takes active, daily commitment, block by block, neighborhood by neighborhood.', 3),
    (4, 'Equitable Economic Development', 'Deputy Mayor, Community and Economic Development', 'Calvin Young, Interim Deputy Mayor', 'Baltimore drives equitable economic growth by investing in neighborhoods, supporting local and minority-owned businesses, strengthening workforce pathways, and attracting investment.', 'Baltimore drives equitable economic growth by investing in neighborhoods that have faced intentional disinvestment, supporting local and minority-owned businesses, strengthening workforce pathways, and positioning the City as a competitive and welcoming destination for investment.', 4),
    (5, 'Responsible Stewardship of City Resources', 'Deputy City Administrator', 'Shamiah Kerney, Deputy City Administrator', 'Baltimore will manage public resources responsibly, maintain fiscal stability, operate an inclusive workforce, deliver reliable services, and govern with transparency and accountability.', 'Baltimore will continue to manage public resources responsibly, maintaining fiscal stability, operating an inclusive, high-performing workforce, delivering reliable City services for all residents, and governing with transparency and accountability. In order to meet our short- and long-term goals, the City must maintain a strong organizational foundation.', 5),
    (6, 'Modernizing Public Infrastructure', 'Deputy Mayor, Operations', 'Khalil Zaied, Deputy Mayor', 'The Scott Administration will modernize public infrastructure by maintaining safe and reliable facilities, transportation, utilities, and digital systems.', 'The Scott Administration will modernize public infrastructure by maintaining safe and reliable facilities, transportation, utilities, and digital systems that support equitable access, economic growth, and long-term resilience. Building a stronger, healthier city requires us to invest in safe roads, clean water, connected communities, and accessible, responsible technology.', 6)
ON CONFLICT (pillar_id) DO UPDATE SET
    pillar_name = EXCLUDED.pillar_name, pillar_lead = EXCLUDED.pillar_lead, pillar_lead_name = EXCLUDED.pillar_lead_name,
    summary = EXCLUDED.summary, overview = EXCLUDED.overview, sort_order = EXCLUDED.sort_order, updated_at = now();

INSERT INTO reference.pillar_goal (pillar_id, goal_code, goal_title, goal_lead, sort_order)
VALUES
    (1, '1.1', 'Disrupt Violent Networks, Stop Gun Trafficking, and Break the Cycle of Repeat Offending Through Evidence-Based Crime Reduction Strategies', 'Director, Mayor''s Office of Neighborhood Safety and Engagement', 1),
    (1, '1.2', 'Develop a National Model for 911 Diversion and Community-Based Interventions', 'Director, Mayor''s Office of Neighborhood Safety and Engagement', 2),
    (1, '1.3', 'Build a Culture of Accountability and Deliver Effective, Equitable Public Safety', 'Police Commissioner and Director, Office of Equity and Civil Rights', 3),
    (2, '2.1', 'Improve Citywide Academic Achievement', 'Assistant Deputy Mayors, Health and Human Services', 1),
    (2, '2.2', 'Create Comprehensive Employment, Career Pathways, and Mentorship Opportunities for Youth and Young Adults', 'Assistant Deputy Mayor, Health and Human Services and Director, Department of Human Resources', 2),
    (2, '2.3', 'Ensure that Older Adults Can Age with Dignity, Independence, and Security', 'Health Commissioner and Director, Mayor''s Office of Older Adult Affairs and Advocacy', 3),
    (2, '2.4', 'Foster a Welcoming, Inclusive City Where Immigrants, LGBTQ Residents, and Other Historically Underserved Communities Thrive', 'Executive Director of Community Affairs and Engagement', 4),
    (3, '3.1', 'Eliminate Environmental Health Disparities and Advance Environmental Justice', 'Health Commissioner and Commissioner, Department of Housing and Community Development', 1),
    (3, '3.2', 'Improve Resident Health Through Expanded Outreach and Prevention Programs', 'Health Commissioner, Director of Homeless Services, and Director of Overdose Response', 2),
    (3, '3.3', 'Improve Neighborhood Livability Through Clean Streets and Green Spaces', 'Director, Department of Public Works', 3),
    (3, '3.4', 'Accelerate Transition to Sustainability and Zero Waste', 'Director, Department of Public Works', 4),
    (4, '4.1', 'Revitalize Neighborhoods Through Strategic, Equitable Investment that Expands Opportunity and Strengthens Communities', 'Commissioner, Department of Housing and Community Development', 1),
    (4, '4.2', 'Position the City as a Competitive and Welcoming Destination for High-Growth, Value-Added Industries and Employers, Including Minority and Women-Owned Businesses', 'President and CEO, Baltimore Development Corporation', 2),
    (4, '4.3', 'Build Workforce Development Systems for All Residents that Lead to Quality Jobs and Career Advancement', 'Director, Mayor''s Office of Employment Development', 3),
    (5, '5.1', 'Maintain Strong Fiscal Health Through Disciplined Budget Management and Financial Accountability', 'Director, Department of Finance', 1),
    (5, '5.2', 'Make the City of Baltimore an Employer of Choice', 'Director, Department of Human Resources', 2),
    (5, '5.3', 'Deliver Excellent, Equitable Customer Service Across All City Agencies', 'Deputy City Administrator', 3),
    (5, '5.4', 'Drive Innovation, Transparency, and Accountability to Improve City Decision-Making and Service Delivery', 'Executive Director, Mayor''s Office of Performance and Innovation', 4),
    (5, '5.5', 'Engage Residents as Partners and Co-Creators in City Decision-Making', 'Director, Mayor''s Office of Community Affairs', 5),
    (6, '6.1', 'Maintain Safe, Functional, and Efficient City Facilities and Fleet', 'Director, Department of General Services', 1),
    (6, '6.2', 'Maintain and Enhance the City''s Transportation Network to Ensure Safety, Reliability, and Efficient Mobility for All Users', 'Director, Department of Transportation', 2),
    (6, '6.3', 'Implement Government-Wide Technologies That Improve Resident and Employee Experience', 'Chief Information Officer and Executive Director, Mayor''s Office of Performance and Innovation', 3),
    (6, '6.4', 'Ensure Reliable, Well-Maintained, and Resilient Utility Systems that Meet Current and Future Demand', 'Bureau Head of Water and Wastewater, Department of Public Works', 4)
ON CONFLICT (goal_code) DO UPDATE SET
    pillar_id = EXCLUDED.pillar_id, goal_title = EXCLUDED.goal_title, goal_lead = EXCLUDED.goal_lead, sort_order = EXCLUDED.sort_order;

INSERT INTO reference.action_plan_initiative (pillar_goal_id, initiative_title, sort_order)
SELECT pg.pillar_goal_id, seed.initiative_title, seed.sort_order
FROM (VALUES
    ('1.1', 'Institutionalize Group Violence Reduction Strategy (GVRS) and intelligence-led policing', 1),
    ('1.1', 'Increase coordination among community violence intervention programs', 2),
    ('1.1', 'Strengthen and evolve Safe Streets operations and conduct updated data analysis', 3),
    ('1.1', 'Disrupt gun trafficking and illegal supply chains', 4),
    ('1.2', 'Expand alternative and community-based response pathways to reduce avoidable Police and EMS calls', 1),
    ('1.3', 'Strengthen police accountability and oversight systems to ensure timely and transparent internal investigative practices', 1),
    ('1.3', 'Sustain compliance with the federal consent decree', 2),
    ('1.3', 'Improve hiring and retention', 3),
    ('1.3', 'Build sustainable fire and police cadet program', 4),
    ('2.1', 'Build provider capacity to create new high-quality childcare seats and support increased pre-Kindergarten enrollment in Baltimore City', 1),
    ('2.1', 'Partner with City Schools to improve grade-level academic performance, attendance, and chronic absenteeism', 2),
    ('2.1', 'Expand access to in-school athletic opportunities at the elementary and middle school level', 3),
    ('2.2', 'Create coordinated, data-driven education-to-career pathways across City agencies and partners', 1),
    ('2.2', 'Expand paid employment, apprenticeships, and pre-apprenticeships in priority sectors', 2),
    ('2.2', 'Connect disengaged youth to education, training, and employment through targeted outreach and coordinated re-engagement services', 3),
    ('2.2', 'Provide structured mentorship and wraparound supports for youth and young adults through age 24', 4),
    ('2.3', 'Improve access to coordinated, home and community-based services for older adults', 1),
    ('2.3', 'Improve housing stability and financial security for older adults', 2),
    ('2.3', 'Strengthen intergenerational engagement and digital inclusion', 3),
    ('2.4', 'Embed inclusive and culturally responsive engagement across all city agencies through training and equitable service delivery', 1),
    ('2.4', 'Expand access to Municipal ID, language services, and digital inclusion resources to reduce barriers', 2),
    ('2.4', 'Provide support to vulnerable immigrant families through legal, health, and human services', 3),
    ('3.1', 'Reduce exposure to environmental hazards in high-risk households through targeted remediation and prevention', 1),
    ('3.1', 'Expand environmental monitoring and mitigation in historically overburdened communities', 2),
    ('3.2', 'Strengthen overdose prevention, response, and recovery systems', 1),
    ('3.2', 'Broaden access to health services', 2),
    ('3.2', 'Improve access to safe, permanent housing for individuals experiencing housing insecurity and homelessness', 3),
    ('3.3', 'Maintain safe, accessible, and high-quality green spaces across all neighborhoods', 1),
    ('3.3', 'Improve street cleanliness through optimized street sweeping and waste removal operations', 2),
    ('3.4', 'Implement residential and commercial waste diversion', 1),
    ('3.4', 'Expand government composting, green procurement, and energy-efficient buildings', 2),
    ('4.1', 'Reduce vacant and blighted properties through coordinated redevelopment, streamlined disposition, and strategic investment', 1),
    ('4.1', 'Deliver block-level, whole-neighborhood revitalization', 2),
    ('4.1', 'Create a high-performing permitting process that is efficient, predictable, and user-centered', 3),
    ('4.1', 'Expand pathways to stable and affordable housing', 4),
    ('4.2', 'Increase economic activity and occupancy in Downtown and key commercial corridors', 1),
    ('4.2', 'Strengthen and expand place-based marketing and branding', 2),
    ('4.2', 'Support growth of local, small, and minority-owned businesses', 3),
    ('4.3', 'Align workforce pipelines to growth sectors', 1),
    ('4.3', 'Provide occupational skill trainings, career navigation support, and apprenticeship opportunities to job seekers', 2),
    ('5.1', 'Expand automation and digital tools across budgeting, procurement, grants, and revenue collection', 1),
    ('5.1', 'Strengthen financial planning, forecasting, and reporting', 2),
    ('5.1', 'Improve oversight and management of grants, revenues, and expenditures', 3),
    ('5.2', 'Improve recruitment, onboarding, and retention across all agencies', 1),
    ('5.2', 'Implement inclusive workplace practices', 2),
    ('5.2', 'Strengthen employee development and leadership pathways', 3),
    ('5.3', 'Establish citywide customer service standards', 1),
    ('5.3', 'Optimize the 311 customer experience', 2),
    ('5.3', 'Expand self-service, multilingual, and accessible service options', 3),
    ('5.4', 'Require agencies to publish annual performance plans aligned to city goals', 1),
    ('5.4', 'Expand innovation and user-centered design practices', 2),
    ('5.4', 'Improve automation and data collection for all city services', 3),
    ('5.5', 'Strengthen boards and commissions with training and accountability criteria', 1),
    ('5.5', 'Conduct regular resident surveys to gauge satisfaction with city services', 2),
    ('5.5', 'Establish proactive, structured Cabinet-level engagements', 3),
    ('6.1', 'Optimize and modernize the City''s government footprint', 1),
    ('6.1', 'Effectively maintain the City''s current building portfolio', 2),
    ('6.1', 'Modernize and maintain the City government''s vehicle fleet', 3),
    ('6.2', 'Modernize and maintain City transportation infrastructure, prioritizing equitable investment', 1),
    ('6.2', 'Create a first-in-class traffic and parking safety program', 2),
    ('6.3', 'Establish enterprise technology governance and investment prioritization', 1),
    ('6.3', 'Deliver timely and accurate data to improve transparency, operations, and AI adoption', 2),
    ('6.3', 'Build a secure, resilient, and risk-informed technology environment', 3),
    ('6.4', 'Maintain and modernize the City''s conduit, water, stormwater, and wastewater infrastructure', 1),
    ('6.4', 'Promote enrollment in water affordability programs', 2)
) AS seed(goal_code, initiative_title, sort_order)
JOIN reference.pillar_goal pg ON pg.goal_code = seed.goal_code
ON CONFLICT (pillar_goal_id, sort_order) DO UPDATE SET initiative_title = EXCLUDED.initiative_title;

-- reference.action_plan_measure's seed rows were removed 2026-07-27 --
-- that table held dummy data from another bot, not real Action Plan
-- measures, and has been dropped (see target_schema.sql). Real Action
-- Plan measures are now any performance.performance_measure marked
-- Citywide (is_city = TRUE) and linked to a pillar.
