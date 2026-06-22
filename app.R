library(shiny)

mock_db <- list(
  reference_agency = data.frame(
    agency_id = c("AGC2600", "AGC4346", "AGC2700", "AGC7000", "AGC5900", "AGC3100", "AGC2500"),
    agency_name = c(
      "Department of General Services",
      "Mayor's Office of Neighborhood Safety and Engagement",
      "Baltimore City Health Department",
      "Department of Transportation",
      "Baltimore Police Department",
      "Housing and Community Development",
      "Baltimore City Fire Department"
    ),
    deputy_mayor_pillar = c(
      "Responsible Stewardship of City Resources",
      "Enhancing Public Safety",
      "Clean, Healthy, and Sustainable Communities",
      "Modernizing Public Infrastructure",
      "Enhancing Public Safety",
      "Equitable Economic Development",
      "Enhancing Public Safety"
    ),
    stringsAsFactors = FALSE
  ),
  planning_agency_plan = data.frame(
    plan_id = c(1, 2, 3, 4, 8, 9, 10),
    agency_id = c("AGC2600", "AGC4346", "AGC2700", "AGC7000", "AGC5900", "AGC3100", "AGC2500"),
    fiscal_year = c(2027, 2027, 2027, 2027, 2027, 2027, 2025),
    plan_status = c("UnderReview", "Approved", "Draft", "FeedbackReturned", "DeputyMayorReview", "CAReview", "Amended"),
    budget_status = c("Draft", "Submitted", "Locked", "Locked", "Locked", "Draft", "Approved"),
    version = c(2, 3, 1, 2, 2, 3, 4),
    submitted_at = c("2026-06-05", "2026-06-08", NA, "2026-06-12", "2026-06-14", "2026-06-09", "2025-05-01"),
    updated_at = c("2026-06-16", "2026-06-22", "2026-06-01", "2026-06-25", "2026-06-17", "2026-06-26", "2025-05-15"),
    stringsAsFactors = FALSE
  ),
  performance_plan_header = data.frame(
    plan_id = c(1, 2, 3, 4, 8, 9, 10),
    primary_contact_name = c("Babila Lima", "Stefanie Mavronis", "Maria Chen", "James Trimarco", "Joseph Muhlhausen", "Happy Iguare", "James Trimarco"),
    primary_contact_email = c(
      "babila.lima@baltimorecity.gov",
      "stefanie.mavronis@baltimorecity.gov",
      "maria.chen@baltimorecity.gov",
      "james.trimarco@baltimorecity.gov",
      "joseph.muhlhausen@baltimorecity.gov",
      "happy.iguare@baltimorecity.gov",
      "james.trimarco@baltimorecity.gov"
    ),
    version_label = c("v1.0", "v1.3", "v1.0", "v1.1", "v1.1", "v1.2", "v1.4"),
    stringsAsFactors = FALSE
  ),
  performance_mission_vision = data.frame(
    plan_id = c(1, 2, 3, 4, 8, 9, 10),
    mission = c(
      "To deliver results for City partners through services and solutions that are timely, cost-effective, and sustainable.",
      "To implement Baltimore's public health approach to violence through prevention, intervention, and victim support.",
      "To protect and promote the health of all Baltimore City residents.",
      "To plan, build, and maintain a safe, accessible, and sustainable transportation network.",
      "To protect the lives and property of Baltimore City residents through community-centered policing.",
      "To expand access to safe, affordable housing for all Baltimore City residents.",
      "To protect life and property through fast, coordinated emergency response."
    ),
    vision = c(
      "To be a leader in delivering expertise, efficiency, and service excellence.",
      "A Baltimore where every neighborhood is safe from violence and every resident has access to support and opportunity.",
      "A healthy Baltimore where every resident can thrive regardless of zip code or income.",
      "A connected Baltimore where every resident can move safely and efficiently.",
      "A Baltimore where every neighborhood is safe and every resident trusts their police department.",
      "A Baltimore where every resident has a safe, stable, and affordable place to call home.",
      "A city where emergency help arrives quickly and reliably in every neighborhood."
    ),
    stringsAsFactors = FALSE
  ),
  reference_service = data.frame(
    service_id = c("SRV0189", "SRV0731", "SRV0924", "SRV0925", "SRV0300", "SRV0670", "SRV0500", "SRV0749", "SRV0750", "SRV0610"),
    agency_id = c("AGC2600", "AGC2600", "AGC4346", "AGC4346", "AGC2700", "AGC7000", "AGC5900", "AGC3100", "AGC3100", "AGC2500"),
    service_name = c(
      "Fleet Management",
      "Facilities Management",
      "Violence Prevention",
      "Victim Services",
      "Communicable Disease Prevention and Control",
      "Traffic Signal and Streetlight Maintenance",
      "Patrol Operations",
      "Property Acquisition, Disposition and Asset Management",
      "Housing Rehabilitation Services",
      "Fire Suppression and Emergency Response"
    ),
    service_type = c("Performance", "Performance", "Performance", "Performance", "Performance", "Performance", "Performance", "Performance", "Performance", "Performance"),
    service_description = c(
      "Acquisition, maintenance, and disposal of the City's vehicle fleet.",
      "Maintenance and operations of City-owned buildings and facilities.",
      "Group Violence Reduction Strategy, Safe Streets, and community violence intervention.",
      "Direct support and advocacy for victims of violence and crime.",
      "Testing, treatment, and outbreak response for communicable diseases.",
      "Installation and maintenance of traffic signals and streetlights.",
      "Community patrol and emergency response operations.",
      "Acquisition and disposition of vacant and city-owned property.",
      "Rehabilitation and lead hazard reduction for City housing stock.",
      "Fire suppression, rescue, and emergency medical response."
    ),
    stringsAsFactors = FALSE
  ),
  performance_plan_service = data.frame(
    plan_service_id = c(1, 2, 3, 4, 5, 6, 9, 7, 8, 10),
    plan_id = c(1, 1, 2, 2, 3, 4, 8, 9, 9, 10),
    service_id = c("SRV0189", "SRV0731", "SRV0924", "SRV0925", "SRV0300", "SRV0670", "SRV0500", "SRV0749", "SRV0750", "SRV0610"),
    sort_order = c(1, 2, 1, 2, 1, 1, 1, 1, 2, 1),
    stringsAsFactors = FALSE
  ),
  performance_agency_goal = data.frame(
    agency_goal_id = c(1, 2, 3, 4, 8, 9, 10),
    plan_id = c(1, 2, 3, 4, 8, 9, 10),
    title = c(
      "Continue effective long-term asset management by rightsizing our vehicle fleet and building portfolio.",
      "Sustain effectiveness of violence intervention models.",
      "Reduce communicable disease transmission through expanded testing and vaccination access.",
      "Improve traffic signal reliability and reduce response time to outages.",
      "Reduce violent crime through community policing strategies.",
      "Expand affordable housing production and preservation.",
      "Improve emergency response times across all districts."
    ),
    description = c(
      "Asset management goal covering Fleet, Facilities, Energy, and Capital Projects.",
      "Citywide violence reduction through GVRS and Safe Streets.",
      "Increase resident access to testing, treatment, and vaccination services.",
      "Modernize and maintain the City's traffic signal network.",
      "Expand foot patrol and community trust-building citywide.",
      "Increase the supply of affordable and preserved housing units.",
      "FY25 historical goal, later amended to add a new KPI."
    ),
    alignment = c(
      "Modernizing Public Infrastructure",
      "Enhancing Public Safety",
      "Clean, Healthy, and Sustainable Communities",
      "Modernizing Public Infrastructure",
      "Enhancing Public Safety",
      "Equitable Economic Development",
      "Modernizing Public Infrastructure"
    ),
    stringsAsFactors = FALSE
  ),
  performance_performance_measure = data.frame(
    measure_id = c(1, 2, 3, 4, 8, 9, 10),
    agency_id = c("AGC2600", "AGC4346", "AGC2700", "AGC7000", "AGC5900", "AGC3100", "AGC2500"),
    title = c(
      "Average Age of Fleet",
      "Citywide Violence Reduction",
      "% of Residents Tested for Communicable Disease Within 48 Hours of Exposure",
      "Average Traffic Signal Outage Response Time",
      "Violent Crime Rate per 1,000 Residents",
      "% of Affordable Housing Units Preserved",
      "Average Emergency Response Time (Minutes)"
    ),
    is_kpi = c(TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE),
    measure_type = c("Outcome", "Outcome", "Effectiveness", "Efficiency", "Outcome", "Outcome", "Efficiency"),
    change_mapping = c("Unchanged", "Unchanged", "New", "New", "Unchanged", "Unchanged", "Unchanged"),
    desired_direction = c("Decrease", "Decrease", "Increase", "Decrease", "Decrease", "Increase", "Decrease"),
    format_type = c("Decimal", "Percent", "Percent", "Days", "Rate", "Percent", "Decimal"),
    display_unit = c("years", NA, NA, NA, "per 1,000 residents", NA, "minutes"),
    validated = c(TRUE, TRUE, FALSE, FALSE, TRUE, TRUE, TRUE),
    data_owner = c("James Trimarco", "Joseph Muhlhausen", "Dr. Anita Roy", "Carlos Reyes", "Capt. Diane Foster", "Devon Carter", "Chief Robert Hale"),
    stringsAsFactors = FALSE
  ),
  performance_measure_actuals = data.frame(
    measure_id = c(1, 2, 3, 4, 8, 9, 10),
    fiscal_year = c(2026, 2026, 2026, 2026, 2026, 2026, 2026),
    annual_actual = c(6.9, -10.2, 62, 5, 38.4, 91, 6.2),
    target_value = c(6.5, -15, 75, 3, 32, 95, 5.5),
    stringsAsFactors = FALSE
  ),
  performance_service_risk = data.frame(
    risk_id = c(1, 2, 3, 4, 8, 9, 10),
    plan_id = c(1, 2, 3, 4, 8, 9, 10),
    description = c(
      "Supply chain delays for replacement vehicle parts could extend fleet downtime beyond targets.",
      "GVRS expansion to new districts depends on continued coordination with BPD and the State's Attorney's Office.",
      "Federal funding uncertainty for communicable disease programs could affect testing capacity.",
      "Aging traffic signal infrastructure increases risk of cascading outages during peak summer heat.",
      "Staffing shortages may limit the pace of community policing foot patrol expansion.",
      "Rising construction costs could reduce the number of affordable units financed within budget.",
      "Dispatch system modernization is contingent on a multi-year IT procurement and integration timeline."
    ),
    mitigation = c(
      "Track vendor delivery dates and prioritize preventive maintenance for high-use vehicles.",
      "Hold monthly partner escalation meetings and document district readiness criteria.",
      "Identify local backup funding and maintain surge testing agreements.",
      "Use Maximo outage trends to prioritize signal cabinet replacement.",
      "Sequence expansion by district staffing levels and recruit overtime volunteers.",
      "Refresh project cost assumptions quarterly and stage awards by readiness.",
      "Coordinate IT milestones with operations training before each deployment."
    ),
    stringsAsFactors = FALSE
  ),
  access_user_agency_access = data.frame(
    agency_id = c("AGC2600", "AGC2600", "AGC4346", "AGC2700", "AGC7000", "AGC5900", "AGC3100", "AGC2500"),
    full_name = c("Babila Lima", "Happy Iguare", "Stefanie Mavronis", "Maria Chen", "James Trimarco", "Joseph Muhlhausen", "Happy Iguare", "James Trimarco"),
    email = c(
      "babila.lima@baltimorecity.gov",
      "happy.iguare@baltimorecity.gov",
      "stefanie.mavronis@baltimorecity.gov",
      "maria.chen@baltimorecity.gov",
      "james.trimarco@baltimorecity.gov",
      "joseph.muhlhausen@baltimorecity.gov",
      "happy.iguare@baltimorecity.gov",
      "james.trimarco@baltimorecity.gov"
    ),
    agency_role = c("Agency Head", "Performance Lead", "Performance Lead", "Performance Lead", "Performance Lead", "Performance Lead", "Performance Lead", "Performance Lead"),
    stringsAsFactors = FALSE
  )
)

pages <- list(
  login = "Login",
  landing = "Cycle home",
  strategic_plan = "City action plan",
  team = "Performance team",
  plan_history = "Plan history & status",
  metrics = "Measures review",
  overview = "Agency overview",
  goals = "Agency goals",
  services = "Agency services",
  risks = "Plan risks"
)

status_tone <- function(status) {
  switch(
    status,
    Approved = "success",
    Submitted = "primary",
    UnderReview = "primary",
    DeputyMayorReview = "primary",
    CAReview = "primary",
    FeedbackReturned = "warning",
    DirectorSignOff = "warning",
    Draft = "warning",
    Amended = "warning",
    "primary"
  )
}

format_status <- function(status) {
  gsub("([a-z])([A-Z])", "\\1 \\2", status)
}

format_measure_value <- function(value, format_type, display_unit = NA) {
  if (is.na(value)) {
    return("Not reported")
  }
  formatted <- switch(
    format_type,
    Percent = paste0(value, "%"),
    Currency = paste0("$", format(value, big.mark = ",", trim = TRUE)),
    Count = format(value, big.mark = ",", trim = TRUE),
    Days = paste(value, "days"),
    Decimal = as.character(value),
    Rate = as.character(value),
    Score = as.character(value),
    as.character(value)
  )
  if (!is.na(display_unit) && !format_type %in% c("Percent", "Days")) {
    formatted <- paste(formatted, display_unit)
  }
  formatted
}

current_plan <- function(db, agency_id) {
  plan <- db$planning_agency_plan[db$planning_agency_plan$agency_id == agency_id & db$planning_agency_plan$fiscal_year == 2027, , drop = FALSE]
  if (nrow(plan) == 0) {
    return(NULL)
  }
  plan[1, , drop = FALSE]
}

agency_name <- function(db, agency_id) {
  agency <- db$reference_agency[db$reference_agency$agency_id == agency_id, , drop = FALSE]
  agency$agency_name[1]
}

selected_context <- function(db, agency_id) {
  plan <- current_plan(db, agency_id)
  agency <- db$reference_agency[db$reference_agency$agency_id == agency_id, , drop = FALSE]
  header <- db$performance_plan_header[db$performance_plan_header$plan_id == plan$plan_id, , drop = FALSE]
  list(agency = agency, plan = plan, header = header)
}

load_reference_extracts <- function() {
  base_path <- file.path("database", "reference")
  read_extract <- function(name) {
    path <- file.path(base_path, paste0(name, ".csv"))
    if (!file.exists(path)) {
      return(data.frame())
    }
    read.csv(path, stringsAsFactors = FALSE, na.strings = c("", "NULL"))
  }

  list(
    agency = read_extract("agency"),
    service = read_extract("service"),
    plan_entity = read_extract("plan_entity"),
    plan_entity_service = read_extract("plan_entity_service")
  )
}

city_reference <- load_reference_extracts()

strategic_plan <- list(
  list(
    id = 1,
    title = "Enhancing Public Safety",
    lead = "Deputy Mayor, Public Safety",
    lead_name = "Samuel Johnson, Assistant Deputy Mayor (Acting)",
    summary = "Baltimore takes an all-of-the-above approach to public safety, holding violent offenders accountable while offering concrete pathways out of criminal activity to those willing to accept.",
    overview = "Baltimore takes an all-of-the-above approach to public safety, holding violent offenders accountable while offering concrete pathways out of criminal activity to those willing to accept. The Scott Administration will build on our successful public safety strategies by continuing to address the root causes of violence, removing firearms from our communities, investing in data-driven proven community violence intervention strategies, responding effectively and efficiently to emergencies, and ensuring accountability and trust across public safety systems.",
    goals = list(
      list(code = "1.1", title = "Disrupt Violent Networks, Stop Gun Trafficking, and Break the Cycle of Repeat Offending Through Evidence-Based Crime Reduction Strategies", lead = "Director, Mayor's Office of Neighborhood Safety and Engagement", initiatives = c("Institutionalize Group Violence Reduction Strategy (GVRS) and intelligence-led policing", "Increase coordination among community violence intervention programs", "Strengthen and evolve Safe Streets operations and conduct updated data analysis", "Disrupt gun trafficking and illegal supply chains")),
      list(code = "1.2", title = "Develop a National Model for 911 Diversion and Community-Based Interventions", lead = "Director, Mayor's Office of Neighborhood Safety and Engagement", initiatives = c("Expand alternative and community-based response pathways to reduce avoidable Police and EMS calls")),
      list(code = "1.3", title = "Build a Culture of Accountability and Deliver Effective, Equitable Public Safety", lead = "Police Commissioner and Director, Office of Equity and Civil Rights", initiatives = c("Strengthen police accountability and oversight systems to ensure timely and transparent internal investigative practices", "Sustain compliance with the federal consent decree", "Improve hiring and retention", "Build sustainable fire and police cadet program"))
    ),
    metrics = list(
      list(name = "Homicides per 100,000 residents", baseline = 47, current = 31, target = 24, direction = "Decrease"),
      list(name = "Non-fatal shootings per 100,000 residents", baseline = 95, current = 54, target = 45, direction = "Decrease"),
      list(name = "Violent Group A crimes per 100k residents", baseline = 960, current = 830, target = 760, direction = "Decrease"),
      list(name = "Consent Decree assessments on track or better", baseline = 61, current = 74, target = 85, direction = "Increase", unit = "%"),
      list(name = "Residents citing crime and drugs as a top issue", baseline = 42, current = 35, target = 28, direction = "Decrease", unit = "%"),
      list(name = "Uniformed positions filled", baseline = 78, current = 82, target = 90, direction = "Increase", unit = "%"),
      list(name = "Eligible 911 calls appropriately diverted", baseline = 8, current = 17, target = 30, direction = "Increase", unit = "%")
    )
  ),
  list(
    id = 2,
    title = "Prioritizing Youth, Older Adults, and Vulnerable Communities",
    lead = "Deputy Mayor, Health and Human Services",
    lead_name = "Dr. Letitia Dzirasa, Deputy Mayor",
    summary = "The Scott Administration will prioritize youth, older adults, and diverse communities through workforce pipelines, mentorship, schools, recreation facilities, and supports that help legacy residents age in place.",
    overview = "The Scott Administration will prioritize youth, older adults, and diverse communities by investing in workforce pipelines, mentorship opportunities, schools, and recreation facilities; protecting the legacy residents who built our city and deserve to age in place; and delivering intentional investment to counter decades of intentional disinvestment.",
    goals = list(
      list(code = "2.1", title = "Improve Citywide Academic Achievement", lead = "Assistant Deputy Mayors, Health and Human Services", initiatives = c("Build provider capacity to create new high-quality childcare seats and support increased pre-Kindergarten enrollment in Baltimore City", "Partner with City Schools to improve grade-level academic performance, attendance, and chronic absenteeism", "Expand access to in-school athletic opportunities at the elementary and middle school level")),
      list(code = "2.2", title = "Create Comprehensive Employment, Career Pathways, and Mentorship Opportunities for Youth and Young Adults", lead = "Assistant Deputy Mayor, Health and Human Services and Director, Department of Human Resources", initiatives = c("Create coordinated, data-driven education-to-career pathways across City agencies and partners", "Expand paid employment, apprenticeships, and pre-apprenticeships in priority sectors", "Connect disengaged youth to education, training, and employment through targeted outreach and coordinated re-engagement services", "Provide structured mentorship and wraparound supports for youth and young adults through age 24")),
      list(code = "2.3", title = "Ensure that Older Adults Can Age with Dignity, Independence, and Security", lead = "Health Commissioner and Director, Mayor's Office of Older Adult Affairs and Advocacy", initiatives = c("Improve access to coordinated, home and community-based services for older adults", "Improve housing stability and financial security for older adults", "Strengthen intergenerational engagement and digital inclusion")),
      list(code = "2.4", title = "Foster a Welcoming, Inclusive City Where Immigrants, LGBTQ Residents, and Other Historically Underserved Communities Thrive", lead = "Executive Director of Community Affairs and Engagement", initiatives = c("Embed inclusive and culturally responsive engagement across all city agencies through training and equitable service delivery", "Expand access to Municipal ID, language services, and digital inclusion resources to reduce barriers", "Provide support to vulnerable immigrant families through legal, health, and human services"))
    ),
    metrics = list(
      list(name = "Students reading at grade level by grade three", baseline = 26, current = 31, target = 45, direction = "Increase", unit = "%"),
      list(name = "Quality early childhood seats funded by Baltimore City", baseline = 1200, current = 1750, target = 2500, direction = "Increase"),
      list(name = "Youth ages 16-24 not in school nor working", baseline = 14, current = 12, target = 9, direction = "Decrease", unit = "%"),
      list(name = "Youth placed in paid employment or apprenticeships annually", baseline = 3200, current = 4100, target = 5500, direction = "Increase"),
      list(name = "Language access compliance rate", baseline = 62, current = 76, target = 90, direction = "Increase", unit = "%"),
      list(name = "Legacy homeowner households contacted and remaining in homes", baseline = 52, current = 68, target = 82, direction = "Increase", unit = "%"),
      list(name = "Households served by Safe City Baltimore and BNAAC", baseline = 900, current = 1350, target = 2000, direction = "Increase"),
      list(name = "Employees completing LGBTQ+ Equity and Inclusiveness training", baseline = 38, current = 57, target = 85, direction = "Increase", unit = "%")
    )
  ),
  list(
    id = 3,
    title = "Clean, Healthy, and Sustainable Communities",
    lead = "Deputy Mayor, Operations and Deputy Mayor, Health and Human Services",
    lead_name = "Khalil Zaied and Dr. Letitia Dzirasa, Deputy Mayors",
    summary = "Baltimore promotes clean, healthy, and sustainable communities by tackling environmental health disparities, improving quality of life, and advancing long-term sustainability.",
    overview = "Baltimore promotes clean, healthy, and sustainable communities by tackling environmental health disparities, improving quality of life, and advancing long-term sustainability for current and future generations. We are committed to clean streets, green spaces, and public health systems that meet the needs of our communities. Building a cleaner, healthier Baltimore takes active, daily commitment, block by block, neighborhood by neighborhood.",
    goals = list(
      list(code = "3.1", title = "Eliminate Environmental Health Disparities and Advance Environmental Justice", lead = "Health Commissioner and Commissioner, Department of Housing and Community Development", initiatives = c("Reduce exposure to environmental hazards in high-risk households through targeted remediation and prevention", "Expand environmental monitoring and mitigation in historically overburdened communities")),
      list(code = "3.2", title = "Improve Resident Health Through Expanded Outreach and Prevention Programs", lead = "Health Commissioner, Director of Homeless Services, and Director of Overdose Response", initiatives = c("Strengthen overdose prevention, response, and recovery systems", "Broaden access to health services", "Improve access to safe, permanent housing for individuals experiencing housing insecurity and homelessness")),
      list(code = "3.3", title = "Improve Neighborhood Livability Through Clean Streets and Green Spaces", lead = "Director, Department of Public Works", initiatives = c("Maintain safe, accessible, and high-quality green spaces across all neighborhoods", "Improve street cleanliness through optimized street sweeping and waste removal operations")),
      list(code = "3.4", title = "Accelerate Transition to Sustainability and Zero Waste", lead = "Director, Department of Public Works", initiatives = c("Implement residential and commercial waste diversion", "Expand government composting, green procurement, and energy-efficient buildings"))
    ),
    metrics = list(
      list(name = "Overdose mortality reduction from 2024 baseline", baseline = 0, current = 8, target = 20, direction = "Increase", unit = "%"),
      list(name = "Infant mortality rate", baseline = 8.2, current = 7.6, target = 6.5, direction = "Decrease"),
      list(name = "Homes weatherized or treated for lead hazards", baseline = 850, current = 1125, target = 1600, direction = "Increase"),
      list(name = "Reported dirty streets and alleys per 1,000 residents", baseline = 41, current = 36, target = 28, direction = "Decrease"),
      list(name = "Maryland Recycling Act diversion rate", baseline = 24, current = 29, target = 40, direction = "Increase", unit = "%"),
      list(name = "City electricity usage from renewable sources", baseline = 18, current = 31, target = 55, direction = "Increase", unit = "%"),
      list(name = "Point-in-Time count of individuals experiencing homelessness", baseline = 1551, current = 1475, target = 1300, direction = "Decrease")
    )
  ),
  list(
    id = 4,
    title = "Equitable Economic Development",
    lead = "Deputy Mayor, Community and Economic Development",
    lead_name = "Calvin Young, Interim Deputy Mayor",
    summary = "Baltimore drives equitable economic growth by investing in neighborhoods, supporting local and minority-owned businesses, strengthening workforce pathways, and attracting investment.",
    overview = "Baltimore drives equitable economic growth by investing in neighborhoods that have faced intentional disinvestment, supporting local and minority-owned businesses, strengthening workforce pathways, and positioning the City as a competitive and welcoming destination for investment.",
    goals = list(
      list(code = "4.1", title = "Revitalize Neighborhoods Through Strategic, Equitable Investment that Expands Opportunity and Strengthens Communities", lead = "Commissioner, Department of Housing and Community Development", initiatives = c("Reduce vacant and blighted properties through coordinated redevelopment, streamlined disposition, and strategic investment", "Deliver block-level, whole-neighborhood revitalization", "Create a high-performing permitting process that is efficient, predictable, and user-centered", "Expand pathways to stable and affordable housing")),
      list(code = "4.2", title = "Position the City as a Competitive and Welcoming Destination for High-Growth, Value-Added Industries and Employers, Including Minority and Women-Owned Businesses", lead = "President and CEO, Baltimore Development Corporation", initiatives = c("Increase economic activity and occupancy in Downtown and key commercial corridors", "Strengthen and expand place-based marketing and branding", "Support growth of local, small, and minority-owned businesses")),
      list(code = "4.3", title = "Build Workforce Development Systems for All Residents that Lead to Quality Jobs and Career Advancement", lead = "Director, Mayor's Office of Employment Development", initiatives = c("Align workforce pipelines to growth sectors", "Provide occupational skill trainings, career navigation support, and apprenticeship opportunities to job seekers"))
    ),
    metrics = list(
      list(name = "Total vacant building notices", baseline = 14500, current = 11800, target = 9000, direction = "Decrease"),
      list(name = "Cost-burdened homeowners rate", baseline = 31, current = 29, target = 25, direction = "Decrease", unit = "%"),
      list(name = "Cost-burdened renters rate", baseline = 54, current = 51, target = 45, direction = "Decrease", unit = "%"),
      list(name = "Individual average taxable gross income", baseline = 47500, current = 50200, target = 56000, direction = "Increase", unit = "$"),
      list(name = "Unemployment rate", baseline = 7.4, current = 6.2, target = 5.1, direction = "Decrease", unit = "%"),
      list(name = "Labor force participation rate", baseline = 62, current = 64, target = 68, direction = "Increase", unit = "%"),
      list(name = "Downtown office occupancy rate", baseline = 68, current = 72, target = 82, direction = "Increase", unit = "%"),
      list(name = "Estimated total visitation to Baltimore", baseline = 24.5, current = 27.2, target = 32, direction = "Increase", unit = "M")
    )
  ),
  list(
    id = 5,
    title = "Responsible Stewardship of City Resources",
    lead = "Deputy City Administrator",
    lead_name = "Shamiah Kerney, Deputy City Administrator",
    summary = "Baltimore will manage public resources responsibly, maintain fiscal stability, operate an inclusive workforce, deliver reliable services, and govern with transparency and accountability.",
    overview = "Baltimore will continue to manage public resources responsibly, maintaining fiscal stability, operating an inclusive, high-performing workforce, delivering reliable City services for all residents, and governing with transparency and accountability. In order to meet our short- and long-term goals, the City must maintain a strong organizational foundation.",
    goals = list(
      list(code = "5.1", title = "Maintain Strong Fiscal Health Through Disciplined Budget Management and Financial Accountability", lead = "Director, Department of Finance", initiatives = c("Expand automation and digital tools across budgeting, procurement, grants, and revenue collection", "Strengthen financial planning, forecasting, and reporting", "Improve oversight and management of grants, revenues, and expenditures")),
      list(code = "5.2", title = "Make the City of Baltimore an Employer of Choice", lead = "Director, Department of Human Resources", initiatives = c("Improve recruitment, onboarding, and retention across all agencies", "Implement inclusive workplace practices", "Strengthen employee development and leadership pathways")),
      list(code = "5.3", title = "Deliver Excellent, Equitable Customer Service Across All City Agencies", lead = "Deputy City Administrator", initiatives = c("Establish citywide customer service standards", "Optimize the 311 customer experience", "Expand self-service, multilingual, and accessible service options")),
      list(code = "5.4", title = "Drive Innovation, Transparency, and Accountability to Improve City Decision-Making and Service Delivery", lead = "Executive Director, Mayor's Office of Performance and Innovation", initiatives = c("Require agencies to publish annual performance plans aligned to city goals", "Expand innovation and user-centered design practices", "Improve automation and data collection for all city services")),
      list(code = "5.5", title = "Engage Residents as Partners and Co-Creators in City Decision-Making", lead = "Director, Mayor's Office of Community Affairs", initiatives = c("Strengthen boards and commissions with training and accountability criteria", "Conduct regular resident surveys to gauge satisfaction with city services", "Establish proactive, structured Cabinet-level engagements"))
    ),
    metrics = list(
      list(name = "City credit rating", baseline = 78, current = 82, target = 90, direction = "Increase", unit = "score"),
      list(name = "Vacant city positions", baseline = 22, current = 18, target = 12, direction = "Decrease", unit = "%"),
      list(name = "City employee retention rate", baseline = 81, current = 84, target = 90, direction = "Increase", unit = "%"),
      list(name = "311 service requests resolved within SLA", baseline = 68, current = 74, target = 85, direction = "Increase", unit = "%"),
      list(name = "Resident satisfaction with City services", baseline = 46, current = 53, target = 65, direction = "Increase", unit = "%")
    )
  ),
  list(
    id = 6,
    title = "Modernizing Public Infrastructure",
    lead = "Deputy Mayor, Operations",
    lead_name = "Khalil Zaied, Deputy Mayor",
    summary = "The Scott Administration will modernize public infrastructure by maintaining safe and reliable facilities, transportation, utilities, and digital systems.",
    overview = "The Scott Administration will modernize public infrastructure by maintaining safe and reliable facilities, transportation, utilities, and digital systems that support equitable access, economic growth, and long-term resilience. Building a stronger, healthier city requires us to invest in safe roads, clean water, connected communities, and accessible, responsible technology.",
    goals = list(
      list(code = "6.1", title = "Maintain Safe, Functional, and Efficient City Facilities and Fleet", lead = "Director, Department of General Services", initiatives = c("Optimize and modernize the City's government footprint", "Effectively maintain the City's current building portfolio", "Modernize and maintain the City government's vehicle fleet")),
      list(code = "6.2", title = "Maintain and Enhance the City's Transportation Network to Ensure Safety, Reliability, and Efficient Mobility for All Users", lead = "Director, Department of Transportation", initiatives = c("Modernize and maintain City transportation infrastructure, prioritizing equitable investment", "Create a first-in-class traffic and parking safety program")),
      list(code = "6.3", title = "Implement Government-Wide Technologies That Improve Resident and Employee Experience", lead = "Chief Information Officer and Executive Director, Mayor's Office of Performance and Innovation", initiatives = c("Establish enterprise technology governance and investment prioritization", "Deliver timely and accurate data to improve transparency, operations, and AI adoption", "Build a secure, resilient, and risk-informed technology environment")),
      list(code = "6.4", title = "Ensure Reliable, Well-Maintained, and Resilient Utility Systems that Meet Current and Future Demand", lead = "Bureau Head of Water and Wastewater, Department of Public Works", initiatives = c("Maintain and modernize the City's conduit, water, stormwater, and wastewater infrastructure", "Promote enrollment in water affordability programs"))
    ),
    metrics = list(
      list(name = "Facility Conditions Index", baseline = 0.19, current = 0.16, target = 0.12, direction = "Decrease"),
      list(name = "Average age of fleet", baseline = 7.4, current = 6.9, target = 6.2, direction = "Decrease", unit = "years"),
      list(name = "Linear miles of bike infrastructure constructed", baseline = 6, current = 11, target = 22, direction = "Increase"),
      list(name = "Lane miles repaved", baseline = 72, current = 91, target = 125, direction = "Increase"),
      list(name = "Water main breaks per 100 miles", baseline = 32, current = 28, target = 22, direction = "Decrease"),
      list(name = "Sanitary sewer overflows per 100 miles", baseline = 11, current = 8, target = 5, direction = "Decrease"),
      list(name = "Fatal and serious injury crashes per capita", baseline = 14.8, current = 12.5, target = 9.5, direction = "Decrease"),
      list(name = "Linear footage of conduit rehabilitated", baseline = 1500, current = 2400, target = 4000, direction = "Increase"),
      list(name = "Low-income households participating in Water4All", baseline = 21, current = 30, target = 45, direction = "Increase", unit = "%"),
      list(name = "Households with broadband internet subscription", baseline = 78, current = 82, target = 90, direction = "Increase", unit = "%")
    )
  )
)

nav_item <- function(id, label, icon_tag, section = NULL) {
  tags$button(
    type = "button",
    class = paste("nav-item", if (!is.null(section)) "nav-subitem" else ""),
    `data-page` = id,
    `aria-label` = label,
    span(class = "nav-icon", `aria-hidden` = "true", icon_tag),
    span(class = "nav-label", label)
  )
}

status_chip <- function(label, tone = "primary") {
  span(class = paste("status-chip", paste0("tone-", tone)), label)
}

metric_tile <- function(label, value, detail = NULL, tone = NULL) {
  div(
    class = paste("metric-tile", if (!is.null(tone)) paste0("tone-", tone) else ""),
    div(class = "metric-label", label),
    div(class = "metric-value", value),
    if (!is.null(detail)) div(class = "metric-detail", detail)
  )
}

action_plan_stat <- function(value, label) {
  div(
    class = "metric-tile action-plan-stat",
    div(class = "metric-value", value),
    div(class = "metric-label", label)
  )
}

deadline_item <- function(date, title, detail, tone = "primary") {
  div(
    class = "deadline-item",
    div(class = paste("deadline-date", paste0("tone-", tone)), date),
    div(
      class = "deadline-copy",
      tags$strong(title),
      span(detail)
    )
  )
}

surface <- function(title, description = NULL, ..., actions = NULL) {
  tags$section(
    class = "section-surface",
    div(
      class = "surface-header",
      div(
        h2(title),
        if (!is.null(description)) p(description)
      ),
      if (!is.null(actions)) div(class = "surface-actions", actions)
    ),
    ...
  )
}

pillar_by_id <- function(pillar_id) {
  for (pillar in strategic_plan) {
    if (pillar$id == pillar_id) {
      return(pillar)
    }
  }
  NULL
}

metric_number <- function(value, unit = NULL) {
  if (is.null(unit)) {
    return(format(value, big.mark = ",", trim = TRUE))
  }
  if (unit == "$") {
    return(paste0("$", format(value, big.mark = ",", trim = TRUE)))
  }
  if (unit == "%") {
    return(paste0(value, "%"))
  }
  paste(format(value, big.mark = ",", trim = TRUE), unit)
}

metric_visual <- function(metric) {
  unit <- metric$unit
  max_value <- max(metric$current, metric$target, na.rm = TRUE)
  current_width <- max(3, round(metric$current / max_value * 100))
  target_position <- min(100, max(3, round(metric$target / max_value * 100)))
  current_label_position <- min(96, max(4, current_width))
  target_label_position <- min(96, max(4, target_position))

  div(
    class = "metric-viz",
    div(
      class = "metric-viz-header",
      tags$strong(metric$name),
      status_chip(metric$direction, "success")
    ),
    div(
      class = "metric-single-bar",
      div(
        class = "metric-bar-track",
        role = "img",
        `aria-label` = paste("Current", metric_number(metric$current, unit), "target", metric_number(metric$target, unit)),
        div(class = "metric-bar current", style = paste0("width: ", current_width, "%;")),
        div(class = "target-marker", style = paste0("left: ", target_position, "%;"))
      ),
      span(class = "metric-bar-value current-value", style = paste0("left: ", current_label_position, "%;"), metric_number(metric$current, unit)),
      span(class = "metric-bar-value target-value", style = paste0("left: ", target_label_position, "%;"), metric_number(metric$target, unit))
    )
  )
}

goal_panel <- function(goal) {
  div(
    class = "goal-detail",
    div(
      class = "goal-detail-header",
      status_chip(paste("Goal", goal$code), "primary"),
      h3(goal$title)
    ),
    p(paste("Goal Lead:", goal$lead)),
    tags$ul(
      class = "initiative-list",
      lapply(seq_along(goal$initiatives), function(index) {
        tags$li(tags$strong(paste0(goal$code, ".", index, " ")), goal$initiatives[[index]])
      })
    )
  )
}

pillar_services <- function(reference, pillar_id) {
  services <- reference$service
  agencies <- reference$agency
  if (nrow(services) == 0 || nrow(agencies) == 0) {
    return(data.frame())
  }
  services <- services[!is.na(services$pillar_id) & services$pillar_id == pillar_id & services$active == "true", , drop = FALSE]
  merge(services, agencies, by = "agency_id", all.x = TRUE)
}

pillar_entities <- function(reference, service_ids) {
  links <- reference$plan_entity_service
  entities <- reference$plan_entity
  if (nrow(links) == 0 || nrow(entities) == 0 || length(service_ids) == 0) {
    return(data.frame())
  }
  links <- links[links$service_id %in% service_ids & links$is_primary == "true", , drop = FALSE]
  merge(links, entities, by = "entity_id", all.x = TRUE)
}

service_hierarchy <- function(service_rows) {
  if (nrow(service_rows) == 0) {
    return(div(class = "service-hierarchy-empty", "No services are aligned to this pillar."))
  }

  service_rows$deputy_mayor_pillar[is.na(service_rows$deputy_mayor_pillar) | service_rows$deputy_mayor_pillar == ""] <- "Unassigned portfolio"
  service_rows$agency_name[is.na(service_rows$agency_name) | service_rows$agency_name == ""] <- "Unassigned agency"
  service_rows <- unique(service_rows[, c("deputy_mayor_pillar", "agency_name", "service_name"), drop = FALSE])
  service_rows <- service_rows[order(service_rows$deputy_mayor_pillar, service_rows$agency_name, service_rows$service_name), , drop = FALSE]

  portfolios <- unique(service_rows$deputy_mayor_pillar)
  div(
    class = "service-hierarchy",
    `aria-label` = "Services grouped by deputy mayor portfolio and agency",
    lapply(portfolios, function(portfolio) {
      portfolio_rows <- service_rows[service_rows$deputy_mayor_pillar == portfolio, , drop = FALSE]
      agencies <- unique(portfolio_rows$agency_name)
      tags$details(
        class = "deputy-service-group",
        open = "open",
        tags$summary(
          span(class = "hierarchy-title", portfolio),
          span(class = "hierarchy-count", paste(length(agencies), if (length(agencies) == 1) "agency" else "agencies", "|", nrow(portfolio_rows), "services"))
        ),
        div(
          class = "agency-service-list",
          lapply(agencies, function(agency) {
            agency_rows <- portfolio_rows[portfolio_rows$agency_name == agency, , drop = FALSE]
            tags$details(
              class = "agency-service-group",
              open = "open",
              tags$summary(
                span(class = "hierarchy-title", agency),
                span(class = "hierarchy-count", paste(nrow(agency_rows), if (nrow(agency_rows) == 1) "service" else "services"))
              ),
              tags$ul(
                class = "hierarchy-service-list",
                lapply(agency_rows$service_name, tags$li)
              )
            )
          })
        )
      )
    })
  )
}

pillar_modal <- function(pillar_id) {
  pillar <- pillar_by_id(pillar_id)
  service_rows <- pillar_services(city_reference, pillar_id)
  service_rows <- service_rows[order(service_rows$agency_name, service_rows$service_name), , drop = FALSE]
  entity_rows <- pillar_entities(city_reference, unique(service_rows$service_id))

  div(
    class = "custom-modal-backdrop",
    `data-close-input` = "close_pillar_modal",
    div(
      class = "custom-modal",
      div(
        class = "custom-modal-header",
        h2(paste0("Pillar ", pillar$id, ": ", pillar$title)),
        actionButton("close_pillar_modal", "Close", class = "civic-button secondary small")
      ),
      div(
        class = "modal-section-stack",
        tags$section(
          class = "modal-section-block",
          h3("Overview"),
          p(class = "pillar-overview-copy", pillar$overview),
          div(class = "modal-fact-grid",
              metric_tile("Pillar lead", pillar$lead, pillar$lead_name),
              metric_tile("Goals", length(pillar$goals)),
              metric_tile("Initiatives", sum(vapply(pillar$goals, function(goal) length(goal$initiatives), integer(1)))),
              metric_tile("Services", nrow(service_rows)))
        ),
        tags$section(
          class = "modal-section-block",
          h3("Goals & Initiatives"),
          div(class = "goal-list", lapply(pillar$goals, goal_panel))
        ),
        tags$section(
          class = "modal-section-block",
          h3("Performance Measures"),
          p("These are Action Plan performance measures with dummy prototype values and targets."),
          div(class = "metric-viz-list", lapply(pillar$metrics, metric_visual))
        ),
        tags$section(
          class = "modal-section-block",
          h3("Agencies & Services"),
          service_hierarchy(service_rows),
          if (nrow(entity_rows) > 0) {
            div(
              class = "entity-list",
              h3("Plan entities"),
              div(
                class = "chip-row",
                lapply(seq_len(nrow(entity_rows)), function(i) status_chip(entity_rows$public_name[i], "primary"))
              )
            )
          }
        )
      )
    )
  )
}

page_login <- function() {
  div(
    class = "login-page",
    div(
      class = "login-panel",
      div(
        class = "brand-lockup brand-large",
        div(class = "brand-mark", "B"),
        div(
          div(class = "brand-city", "City of Baltimore"),
          div(class = "brand-product", "Performance Portal"),
          div(class = "brand-subtitle", "Annual planning and performance review")
        )
      ),
      h1("Sign in to continue"),
      p("Use your City staff account to review plans, manage metrics, and submit cycle updates."),
      div(
        class = "login-actions",
        actionButton("login_staff", "Continue with Microsoft Entra", class = "civic-button primary"),
        actionButton("login_admin", "Admin sign in", class = "civic-button secondary")
      ),
      div(class = "support-note", "Need access? Contact 311 Support at help@baltimorecity.gov.")
    )
  )
}

page_landing <- function(db, agency_id) {
  ctx <- selected_context(db, agency_id)
  plan <- ctx$plan
  agency <- ctx$agency
  header <- ctx$header
  services <- db$performance_plan_service[db$performance_plan_service$plan_id == plan$plan_id, , drop = FALSE]
  measures <- db$performance_performance_measure[db$performance_performance_measure$agency_id == agency_id, , drop = FALSE]
  goals <- db$performance_agency_goal[db$performance_agency_goal$plan_id == plan$plan_id, , drop = FALSE]
  risks <- db$performance_service_risk[db$performance_service_risk$plan_id == plan$plan_id, , drop = FALSE]
  validated_count <- sum(measures$validated)

  tagList(
    div(
      class = "briefing-header",
      div(
        div(class = "eyebrow", "Performance cycle"),
        h1(paste0("FY", plan$fiscal_year, " performance planning")),
        p(paste("Track", agency$agency_name, "plan status, assigned contacts, services, measures, and risks before moving into the builder.")),
        div(
          class = "chip-row",
          status_chip(format_status(plan$plan_status), status_tone(plan$plan_status)),
          status_chip(paste("Budget", format_status(plan$budget_status)), status_tone(plan$budget_status)),
          status_chip(paste("Version", plan$version), "primary")
        )
      ),
      div(class = "briefing-meta", paste("Updated", plan$updated_at))
    ),
    div(
      class = "dashboard-grid",
      metric_tile("Current agency", agency$agency_id, agency$deputy_mayor_pillar),
      metric_tile("Services in plan", nrow(services), "performance.plan_service"),
      metric_tile("KPI measures", sum(measures$is_kpi), paste(validated_count, "validated")),
      metric_tile("Open risks", nrow(risks), "performance.service_risk", if (nrow(risks) > 0) "warning" else NULL)
    ),
    surface(
      "Plan record",
      "Prototype view of the current planning.agency_plan and performance.plan_header rows.",
      div(
        class = "app-table",
        div(class = "table-row table-head", span("Field"), span("Value"), span("Source table")),
        div(class = "table-row", span("Plan status"), status_chip(format_status(plan$plan_status), status_tone(plan$plan_status)), span("planning.agency_plan")),
        div(class = "table-row", span("Primary contact"), span(header$primary_contact_name), span("performance.plan_header")),
        div(class = "table-row", span("Contact email"), span(header$primary_contact_email), span("performance.plan_header"))
      )
    ),
    surface(
      "Current plan snapshot",
      "A quick read on the plan sections that are ready or still need work.",
      div(
        class = "progress-list",
        div(class = "progress-row", span("Agency overview"), div(class = "progress-track", div(style = "width: 100%;")), tags$strong("Loaded")),
        div(class = "progress-row", span("Goals and KPIs"), div(class = "progress-track", div(style = paste0("width: ", min(100, nrow(goals) * 35 + nrow(measures) * 15), "%;"))), tags$strong(paste(nrow(goals), "goals"))),
        div(class = "progress-row", span("Services"), div(class = "progress-track", div(style = paste0("width: ", min(100, nrow(services) * 45), "%;"))), tags$strong(paste(nrow(services), "services"))),
        div(class = "progress-row", span("Risks"), div(class = "progress-track", div(style = paste0("width: ", min(100, nrow(risks) * 40), "%;"))), tags$strong(paste(nrow(risks), "risks")))
      )
    )
  )
}

page_strategic_plan <- function(db, agency_id) {
  div(
    class = "action-plan-page",
    div(
      class = "briefing-header compact",
      div(
        div(class = "eyebrow", "2026 Mayor's Action Plan"),
        h1("Mayor Scott's Second Term Action Plan"),
        p("Mayor Scott's Second Term Action Plan aligns the work of City government with the needs and priorities of Baltimore residents. Building on the progress of the Mayor's first term, the plan establishes clear goals, coordinated strategies, and measurable outcomes that guide how the city delivers essential services and invests resources. Alongside the City's 10 Year Financial Plan, it provides a decision-making framework for more efficient and effective government operations."),
        p("Data and accountability ground the plan's development, drawing on agency performance data, service delivery trends, and community needs analysis. From this process, the City identified six core priority areas: enhancing public safety; prioritizing youth, older adults, and vulnerable communities; clean, healthy, and sustainable communities; equitable economic development; responsible stewardship of City resources; and modernizing public infrastructure."),
        p("Each priority is supported by specific, measurable goals and targeted strategies that City agencies incorporate into their work. A performance framework tracks progress on key metrics through regular public reporting, promoting transparency and holding the City accountable to residents as it works toward a stronger, more resilient, and equitable Baltimore. Click through the pillars below to explore each priority area's goals, initiatives, metrics, and services.")
      ),
      tags$a(
        class = "civic-button secondary action-plan-report-link",
        href = "https://s3.amazonaws.com/baltimorecity.gov.if-us-east-1/s3fs-public/2026-05/2026%20Mayor%27s%20Action%20Plan_0.pdf",
        target = "_blank",
        rel = "noopener noreferrer",
        "View the Action Plan Report"
      )
    ),
    div(
      class = "dashboard-grid action-plan-dashboard",
      action_plan_stat(length(strategic_plan), "Pillars"),
      action_plan_stat(sum(vapply(strategic_plan, function(pillar) length(pillar$goals), integer(1))), "Goals"),
      action_plan_stat(sum(vapply(strategic_plan, function(pillar) length(pillar$metrics), integer(1))), "Metrics")
    ),
    surface(
      "Pillars",
      "Open a pillar to review goals, initiatives, metrics, agencies, services, and plan entities.",
      div(
        class = "pillar-grid",
        lapply(strategic_plan, function(pillar) {
          actionButton(
            inputId = paste0("open_pillar_", pillar$id),
            class = "pillar-card pillar-card-button",
            label = tagList(
            div(
              class = "pillar-card-topline",
              h3(paste("Pillar", pillar$id))
            ),
            h4(class = "pillar-card-title", pillar$title),
            p(pillar$summary),
            div(
              class = "pillar-card-meta",
              span(paste(length(pillar$goals), "goals")),
              span(paste(sum(vapply(pillar$goals, function(goal) length(goal$initiatives), integer(1))), "initiatives")),
              span(paste(length(pillar$metrics), "metrics"))
            )
            )
          )
        })
      )
    )
  )
}

page_team <- function(db, agency_id) {
  team <- db$access_user_agency_access[db$access_user_agency_access$agency_id == agency_id, , drop = FALSE]
  if (nrow(team) == 0) {
    team <- data.frame(full_name = "Unassigned", email = "Needs access record", agency_role = "Performance Lead", stringsAsFactors = FALSE)
  }
  surface(
    "Review Performance Team and Roles",
    "Confirm who owns plan sections, metric approvals, and final submission.",
    div(
      class = "app-table",
      div(class = "table-row table-head", span("Role"), span("Owner"), span("Status")),
      lapply(seq_len(nrow(team)), function(i) {
        div(class = "table-row", span(team$agency_role[i]), span(team$full_name[i]), status_chip("Access active", "success"))
      }),
      div(class = "table-row", span("Metric data steward"), span(team$full_name[1]), status_chip("Confirm backup", "warning"))
    )
  )
}

builder_page <- function(title, description, body) {
  tagList(
    div(
      class = "briefing-header compact",
      div(
        div(class = "eyebrow", "Performance plan builder"),
        h1(title),
        p(description)
      ),
      status_chip("Draft", "warning")
    ),
    body
  )
}

page_plan_history <- function(db, agency_id) {
  plans <- db$planning_agency_plan[db$planning_agency_plan$agency_id == agency_id, , drop = FALSE]
  plans <- plans[order(plans$fiscal_year, decreasing = TRUE), , drop = FALSE]
  builder_page(
    "Plan History & Status",
    "Review prior submissions, current review state, and approval notes.",
    surface(
      "Submission timeline",
      NULL,
      div(
        class = "timeline",
        lapply(seq_len(nrow(plans)), function(i) {
          div(
            class = paste("timeline-item", if (plans$fiscal_year[i] == 2027) "current" else "complete"),
            tags$strong(paste0("FY", plans$fiscal_year[i], " ", format_status(plans$plan_status[i]))),
            span(paste("Budget", format_status(plans$budget_status[i]), "| version", plans$version[i], "| updated", plans$updated_at[i]))
          )
        })
      )
    )
  )
}

page_metrics <- function(db, agency_id) {
  measures <- db$performance_performance_measure[db$performance_performance_measure$agency_id == agency_id, , drop = FALSE]
  actuals <- db$performance_measure_actuals
  measure_rows <- merge(measures, actuals, by = "measure_id", all.x = TRUE)
  builder_page(
    "Measures Review/Add/Change",
    "Review current KPIs, request changes, and add measures for the upcoming cycle.",
    surface(
      "Measure change queue",
      "Track add, change, and retire requests before submission.",
      div(
        class = "app-table",
        div(class = "table-row table-head metrics-row", span("Metric"), span("Change"), span("Actual / target"), span("Status")),
        lapply(seq_len(nrow(measure_rows)), function(i) {
          actual <- format_measure_value(measure_rows$annual_actual[i], measure_rows$format_type[i], measure_rows$display_unit[i])
          target <- format_measure_value(measure_rows$target_value[i], measure_rows$format_type[i], measure_rows$display_unit[i])
          div(
            class = "table-row metrics-row",
            span(measure_rows$title[i]),
            span(measure_rows$change_mapping[i]),
            span(paste(actual, "/", target)),
            status_chip(if (measure_rows$validated[i]) "Validated" else "Needs review", if (measure_rows$validated[i]) "success" else "warning")
          )
        })
      )
    )
  )
}

page_overview <- function(db, agency_id) {
  plan <- current_plan(db, agency_id)
  mv <- db$performance_mission_vision[db$performance_mission_vision$plan_id == plan$plan_id, , drop = FALSE]
  builder_page(
    "Agency Overview and Vision",
    "Draft the agency summary, vision statement, and operating context.",
    surface(
      "Overview draft",
      NULL,
      div(class = "form-grid",
          textAreaInput("agency_summary", "Mission", rows = 5, value = mv$mission),
          textAreaInput("agency_vision", "Vision", rows = 5, value = mv$vision))
    )
  )
}

page_goals <- function(db, agency_id) {
  plan <- current_plan(db, agency_id)
  goals <- db$performance_agency_goal[db$performance_agency_goal$plan_id == plan$plan_id, , drop = FALSE]
  builder_page(
    "Agency Goals",
    "Set initiatives, select KPIs, and align each goal to the City Action Plan.",
    surface(
      "Goal alignment",
      NULL,
      div(
        class = "goal-list",
        lapply(seq_len(nrow(goals)), function(i) {
          div(class = "goal-card", h3(goals$title[i]), p(goals$description[i]), status_chip(goals$alignment[i], "primary"))
        })
      )
    )
  )
}

page_services <- function(db, agency_id) {
  plan <- current_plan(db, agency_id)
  plan_services <- db$performance_plan_service[db$performance_plan_service$plan_id == plan$plan_id, , drop = FALSE]
  service_rows <- merge(plan_services, db$reference_service, by = "service_id", all.x = TRUE)
  measures <- db$performance_performance_measure[db$performance_performance_measure$agency_id == agency_id, , drop = FALSE]
  builder_page(
    "Agency Services",
    "Define service descriptions and select measures for each service area.",
    surface(
      "Service catalog",
      NULL,
      div(
        class = "app-table",
        div(class = "table-row table-head", span("Service"), span("Description"), span("Measures")),
        lapply(seq_len(nrow(service_rows)), function(i) {
          div(
            class = "table-row",
            span(service_rows$service_name[i]),
            span(service_rows$service_description[i]),
            span(nrow(measures))
          )
        })
      )
    )
  )
}

page_risks <- function(db, agency_id) {
  plan <- current_plan(db, agency_id)
  risks <- db$performance_service_risk[db$performance_service_risk$plan_id == plan$plan_id, , drop = FALSE]
  builder_page(
    "Plan Risks",
    "Capture delivery risks, mitigations, and unresolved dependencies.",
    surface(
      "Risk register",
      NULL,
      div(
        class = "app-table",
        div(class = "table-row table-head", span("Risk"), span("Mitigation"), span("Tone")),
        lapply(seq_len(nrow(risks)), function(i) {
          div(class = "table-row", span(risks$description[i]), span(risks$mitigation[i]), status_chip("Open", "warning"))
        })
      )
    )
  )
}

page_ui <- function(page, db, agency_id) {
  switch(
    page,
    login = page_login(),
    landing = page_landing(db, agency_id),
    strategic_plan = page_strategic_plan(db, agency_id),
    team = page_team(db, agency_id),
    plan_history = page_plan_history(db, agency_id),
    metrics = page_metrics(db, agency_id),
    overview = page_overview(db, agency_id),
    goals = page_goals(db, agency_id),
    services = page_services(db, agency_id),
    risks = page_risks(db, agency_id),
    page_landing(db, agency_id)
  )
}

ui <- tagList(
  tags$head(
    tags$title("Baltimore Performance Portal"),
    tags$meta(name = "viewport", content = "width=device-width, initial-scale=1"),
    tags$link(rel = "stylesheet", href = "styles.css?v=20260622-9"),
    tags$script(src = "app.js?v=20260622-2", defer = "defer")
  ),
  div(
    class = "app-shell",
    tags$a(class = "skip-link", href = "#main-content", "Skip to content"),
    tags$header(
      class = "app-header",
      div(
        class = "header-inner",
        div(
          class = "brand-lockup",
          div(class = "brand-mark", "B"),
          div(
            div(class = "brand-city", "City of Baltimore"),
            div(class = "brand-product", "Performance Portal")
          )
        ),
        div(class = "header-agency-name", "Department of General Services")
      )
    ),
    div(
      class = "shell-body",
      tags$aside(
        class = "desktop-drawer",
        div(class = "drawer-title", "Navigation"),
        tags$nav(
          class = "drawer-nav",
          nav_item("landing", "Cycle home", icon("house")),
          nav_item("strategic_plan", "Action plan", icon("clipboard-list")),
          nav_item("team", "Team and roles", icon("users")),
          div(class = "nav-group-label", "Plan builder"),
          nav_item("plan_history", "History & status", icon("clock-rotate-left"), "builder"),
          nav_item("overview", "Overview & vision", icon("eye"), "builder"),
          nav_item("goals", "Goals", icon("flag"), "builder"),
          nav_item("services", "Services", icon("briefcase"), "builder"),
          nav_item("metrics", "Measures", icon("chart-line"), "builder"),
          nav_item("risks", "Risks", icon("triangle-exclamation"), "builder")
        )
      ),
      tags$main(
        id = "main-content",
        class = "main-content",
        uiOutput("page")
      )
    ),
    tags$nav(
      class = "mobile-nav",
      nav_item("landing", "Home", icon("house")),
      nav_item("strategic_plan", "Action", icon("clipboard-list")),
      nav_item("team", "Team", icon("users")),
      nav_item("plan_history", "History", icon("clock-rotate-left")),
      nav_item("overview", "Overview", icon("eye")),
      nav_item("goals", "Goals", icon("flag")),
      nav_item("services", "Services", icon("briefcase")),
      nav_item("metrics", "Measures", icon("chart-line")),
      nav_item("risks", "Risks", icon("triangle-exclamation"))
    ),
    tags$footer(
      class = "app-footer",
      div(
        class = "footer-inner",
        div(
          tags$strong("City of Baltimore Performance Portal"),
          span("Shared planning, metrics, and review workspace.")
        ),
        div(
          class = "footer-support",
          span("311 Support"),
          tags$a(href = "mailto:help@baltimorecity.gov", "help@baltimorecity.gov"),
          span("(410) 555-0311")
        )
      )
    ),
    uiOutput("pillar_modal")
  )
)

server <- function(input, output, session) {
  current_page <- reactiveVal("login")
  current_pillar_modal <- reactiveVal(NULL)

  observeEvent(input$current_page, {
    current_page(input$current_page)
  }, ignoreInit = TRUE)

  observeEvent(input$login_staff, {
    current_page("landing")
    session$sendCustomMessage("set-page", "landing")
  })

  observeEvent(input$login_admin, {
    current_page("landing")
    session$sendCustomMessage("set-page", "landing")
  })

  lapply(seq_along(strategic_plan), function(index) {
    local({
      pillar_id <- strategic_plan[[index]]$id
      observeEvent(input[[paste0("open_pillar_", pillar_id)]], {
        current_pillar_modal(pillar_id)
      }, ignoreInit = TRUE)
    })
  })

  observeEvent(input$close_pillar_modal, {
    current_pillar_modal(NULL)
  }, ignoreInit = TRUE)

  output$page <- renderUI({
    agency_id <- input$selected_agency
    if (is.null(agency_id) || !agency_id %in% mock_db$reference_agency$agency_id) {
      agency_id <- "AGC2600"
    }
    page_ui(current_page(), mock_db, agency_id)
  })

  output$pillar_modal <- renderUI({
    pillar_id <- current_pillar_modal()
    if (is.null(pillar_id)) {
      return(NULL)
    }
    pillar_modal(pillar_id)
  })
}

shinyApp(ui, server)
