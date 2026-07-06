from pathlib import Path

import pandas as pd

SOURCE = Path(r"C:\Users\melanie.lada\Downloads\User_Roles (2).xlsx")
OUT_DIR = Path("tmp_user_roles_update")


def clean(value):
    if pd.isna(value):
        return ""
    value = str(value).strip()
    if value == "\xa0":
        return ""
    return value


def read_sheet(sheet):
    df = pd.read_excel(SOURCE, sheet_name=sheet, dtype=str)
    df = df.rename(columns={col: clean(col) for col in df.columns})
    for col in df.columns:
        df[col] = df[col].map(clean)
    return df


def main():
    OUT_DIR.mkdir(exist_ok=True)
    sheets = {
        "USER": "user.csv",
        "USER_ROLE": "user_role.csv",
        "USER_FUNCTIONS": "user_functions.csv",
        "DH_USERLIST With Entities": "dh_userlist_with_entities.csv",
    }
    for sheet, filename in sheets.items():
        df = read_sheet(sheet)
        df.to_csv(OUT_DIR / filename, index=False)
        print(f"{sheet}: {len(df)} rows -> {OUT_DIR / filename}")


if __name__ == "__main__":
    main()
