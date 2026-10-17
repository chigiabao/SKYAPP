"""
Convert Excel weather data to SQLite database.
Skips rows before 2017-01-01 as they contain errors.
"""
import pandas as pd
import sqlite3
from pathlib import Path


def convert_excel_to_sqlite():
    # Paths
    backend_dir = Path(__file__).resolve().parent
    excel_path = backend_dir.parent / "data" / "10 tháng 10 2016 - 10 tháng 10 2026.xlsx"
    db_path = backend_dir / "data" / "weather.db"

    print(f"Reading Excel file: {excel_path}")

    # Read Excel without header first to find the actual header row
    df_raw = pd.read_excel(excel_path, header=None, nrows=10)

    # Find the row that contains 'time' as the first non-null value
    header_row = None
    for i in range(10):
        first_val = str(df_raw.iloc[i, 0]).strip().lower()
        if first_val == 'time':
            header_row = i
            break

    if header_row is None:
        raise ValueError("Could not find header row with 'time' column")

    print(f"Found header at row: {header_row}")

    # Read Excel with correct header row
    df = pd.read_excel(excel_path, header=header_row)

    print(f"Total rows read: {len(df)}")
    print(f"Columns: {list(df.columns)}")

    # Rename columns to clean database-friendly names
    column_mapping = {
        'time': 'timestamp',
        'temperature_2m (°C)': 'temperature',
        'relative_humidity_2m (%)': 'humidity',
        'dew_point_2m (°C)': 'dew_point',
        'apparent_temperature (°C)': 'apparent_temperature',
        'precipitation_probability (%)': 'precipitation_probability',
        'precipitation (mm)': 'precipitation',
        'rain (mm)': 'rain',
        'showers (mm)': 'showers',
        'snowfall (cm)': 'snowfall',
        'snow_depth (m)': 'snow_depth',
        'vapour_pressure_deficit (kPa)': 'vapour_pressure_deficit',
        'et0_fao_evapotranspiration (mm)': 'et0_evapotranspiration',
        'evapotranspiration (mm)': 'evapotranspiration',
        'visibility (m)': 'visibility',
        'cloud_cover_high (%)': 'cloud_cover_high',
        'cloud_cover_mid (%)': 'cloud_cover_mid',
        'cloud_cover_low (%)': 'cloud_cover_low',
        'cloud_cover (%)': 'cloud_cover',
        'surface_pressure (hPa)': 'surface_pressure',
        'pressure_msl (hPa)': 'pressure_msl',
        'weather_code (wmo code)': 'weather_code',
        'wind_speed_10m (km/h)': 'wind_speed',
        'wind_direction_10m (°)': 'wind_direction',
        'wind_gusts_10m (km/h)': 'wind_gusts',
    }

    # Handle potential encoding issues with degree symbol
    new_columns = {}
    for old_col in df.columns:
        # Try exact match first
        if old_col in column_mapping:
            new_columns[old_col] = column_mapping[old_col]
        else:
            # Try matching without special characters
            clean_old = old_col.replace('°', '').replace('�', '')
            for map_key, map_val in column_mapping.items():
                clean_key = map_key.replace('°', '').replace('�', '')
                if clean_old == clean_key:
                    new_columns[old_col] = map_val
                    break

    # Rename matched columns
    df = df.rename(columns=new_columns)

    # Select only the columns we need
    needed_columns = [
        'timestamp', 'temperature', 'humidity', 'dew_point', 'apparent_temperature',
        'precipitation_probability', 'precipitation', 'rain', 'weather_code',
        'visibility', 'cloud_cover', 'surface_pressure', 'pressure_msl',
        'wind_speed', 'wind_direction', 'wind_gusts'
    ]

    # Keep only columns that exist
    existing_columns = [col for col in needed_columns if col in df.columns]
    df = df[existing_columns]

    print(f"Selected columns: {existing_columns}")

    # The sheet stacks an hourly block then a daily block; the daily block starts at a repeated 'time' header.
    daily_header = df.index[df['timestamp'].astype(str) == 'time']
    if len(daily_header):
        df = df.loc[: daily_header[0] - 1]

    df['timestamp'] = pd.to_datetime(df['timestamp'], errors='coerce')
    value_columns = [c for c in df.columns if c != 'timestamp']
    df[value_columns] = df[value_columns].apply(pd.to_numeric, errors='coerce')

    # Remove any rows with invalid timestamps
    df = df.dropna(subset=['timestamp'])

    # Filter out rows before 2017-01-01 (they have errors)
    df = df[df['timestamp'] >= '2017-01-01']
    print(f"Rows after filtering (>= 2017-01-01): {len(df)}")

    # Remove rows with all NaN values (except timestamp)
    df = df.dropna(subset=['temperature'], how='all')
    print(f"Rows after removing invalid data: {len(df)}")

    # Show sample data
    print("\nSample data:")
    print(df.head(5).to_string())
    print(f"\nDate range: {df['timestamp'].min()} to {df['timestamp'].max()}")

    # Create SQLite database
    print(f"\nCreating SQLite database: {db_path}")

    # Remove existing database if exists
    if db_path.exists():
        db_path.unlink()

    conn = sqlite3.connect(db_path)

    # Write to database
    df.to_sql('hourly_weather', conn, index=False, if_exists='replace')

    # Create index on timestamp for fast queries
    cursor = conn.cursor()
    cursor.execute('CREATE INDEX idx_timestamp ON hourly_weather(timestamp)')

    # Verify data
    cursor.execute('SELECT COUNT(*) FROM hourly_weather')
    count = cursor.fetchone()[0]
    print(f"\nRows inserted into database: {count}")

    cursor.execute('SELECT * FROM hourly_weather LIMIT 3')
    rows = cursor.fetchall()
    print("\nSample rows from database:")
    for row in rows:
        print(row)

    conn.close()
    print(f"\nDatabase created successfully: {db_path}")


if __name__ == "__main__":
    convert_excel_to_sqlite()
