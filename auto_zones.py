import sys
import os
import pandas as pd     # python's main data analysis library. It organises data into structured 2d tables called dataframes i.e. spreadsheets but in python code. Think of it as a dictionary with column names as the keys and the data in each column as the value. Data in each column are stored in a list paired to its corresponding column name. Hence, the syntax is basically the same as accessing a python dictionary 
import psycopg2     # Library that helps connect Python to the SQL database 
import numpy as np
from dotenv import load_dotenv     # Loads variables from a local .env file into the environment so credentials never get hardcoded/committed
from sklearn.cluster import KMeans
from sklearn.metrics import silhouette_score
from shapely.geometry import MultiPoint

load_dotenv()

# 1. Database Connection Configuration
# Pulled from environment variables (see .env.example) instead of being hardcoded, so real credentials never end up in git
DB_CONFIG = {
    "dbname": os.environ["DB_NAME"],
    "user": os.environ["DB_USER"],
    "password": os.environ["DB_PASSWORD"],
    "host": os.environ["DB_HOST"],
    "port": os.environ["DB_PORT"]
}

def get_existing_centroids(conn):
    """Fetches the center point coordinates (centroids) of current active zones from PostGIS."""
    query = """
        SELECT 
            ST_X(ST_Centroid(boundary)) AS longitude, 
            ST_Y(ST_Centroid(boundary)) AS latitude 
        FROM zones 
        WHERE status = 'Active'
        ORDER BY id;
    """
    df = pd.read_sql(query, conn)
    if len(df) == 0:
        return None
    return df[['longitude', 'latitude']].to_numpy() # Returns a numpy array of tuples of coords of current centroids
    # df[['longitude', 'latitude']] tells pandas to extract a mini table from the dataframe containing only the two selected columns, if want only one column it becomes df['latitude'].
    # .to_numpy removes the column headers and tuirns the rows into an array of floats like [[103.85, 1.29], [103.86, 1.30]]

# Used for full restructing of zones to find the best possible zones, FULLY DISREGARDING the current zones (useful for things like once a qtr/year optimisations)
def find_optimal_clusters(df, min_k=2, max_k=6):    
    """
    Calculates best cluster count K dynamically using Silhouette Score.
    Tries to find the clusters where there is the highest spatial separation between clusters so that there are no overlaps and delivery times can be shorter as clusters are tighter 
    """
    X = df[['longitude', 'latitude']]   # Extracts a mini table from the df with only these two columns
    best_k = min_k
    best_score = -1 # Starts from the worst possible SS 
    best_labels = None

    max_k = min(max_k, len(df) - 1)
    if max_k < min_k:
        return 0, df

    for k in range(min_k, max_k + 1):
        kmeans = KMeans(n_clusters=k, random_state=42, n_init=10)   # random_state = 42 is like a set of random starting points (centroids) to tell n_init = 10 which 10 sets of centroids to use. This is to ensure that the zones are reproducible each time the script is ran.
        labels = kmeans.fit_predict(X)  # stores an array of assigned cluster number for each package, determined by kmeans clustering algo
        score = silhouette_score(X, labels) # (poor clustering) -1 < SS < 1 (good clustering, packages in the same zone are very close together and different zones are far apart)

        if score > best_score:
            best_score = score
            best_k = k
            best_labels = labels

    print(f"[REBALANCE MODE] Optimal zone count determined: {best_k} zones (Silhouette Score: {best_score:.2f})")
    df['cluster'] = best_labels # Updates the 'cluster' column with the current best labels for each package 
    return best_k, df


def auto_generate_zones(mode="adjust"):
    conn = psycopg2.connect(**DB_CONFIG)
    cursor = conn.cursor()  # A cursor is a control structure used to execute SQL commands and retrieve results from a database over a network/driver connection.

    try:
        # 2. Extract package coordinates from PostGIS
        query = """
            SELECT 
                id, 
                ST_X(destination) AS longitude, 
                ST_Y(destination) AS latitude 
            FROM packages;
        """
        df = pd.read_sql(query, conn)   # pandas sends the query across the database connectin, conn. SQL processes the query and sends the rows back and pandas turn it into tabular dataframes that can be fed into scikit-learn later 
        X = df[['longitude', 'latitude']]

        if len(df) < 3:
            print(f"Insufficient package data ({len(df)} packages) to construct zone boundaries.")
            return

        # 3. Determine Clustering Execution Strategy
        existing_centroids = get_existing_centroids(conn)

        if mode == "adjust" and existing_centroids is not None:
            print(f"[ADJUST MODE] Warm-starting K-Means using {len(existing_centroids)} existing zone centroids...")
            
            # Incremental Update: Start directly at existing zone centers
            kmeans = KMeans(
                n_clusters=len(existing_centroids),
                init=existing_centroids,
                n_init=1
            )
            df['cluster'] = kmeans.fit_predict(X)
            num_zones = len(existing_centroids)

        else:
            print("[REBALANCE MODE] Performing full re-clustering from scratch...")
            
            # Strategic Reset: Dynamically select optimal K and run full K-Means
            num_zones, df = find_optimal_clusters(df, min_k=2, max_k=6)
            if num_zones == 0:
                return

        # 4. Construct Convex Hull Polygon Boundaries
        for cluster_id in range(num_zones):
            cluster_points = df[df['cluster'] == cluster_id]    # Internal df['cluster'] == cluster_id comapares the packages based on the 'cluster' column and generate a list of True/False booleans. The outer df[] apply the True/False mask onto the dataframe and keeps the true rows while discarding the false, essentially applying a filter to get only the rows of package data where the package comes from the specified cluster
            points = list(zip(cluster_points['longitude'], cluster_points['latitude'])) # cluster_points[] get the columns of longitude and latitude which is zipped together to form a list of tuples containing coordinates of the points in the specified zone

            if len(points) < 3:
                print(f"Cluster {cluster_id} has fewer than 3 packages. Skipping boundary update.")
                continue

            multi_point = MultiPoint(points)    # Turns the tuples of coordinates into a single spatial collection object 
            polygon_hull = multi_point.convex_hull  # Uses the convex hull algo to find the smallest convex polygon that encloses all the points in a collection, converting a MultiPoint object into a Polygon geometry object 
            wkt_polygon = polygon_hull.wkt  # Need to converet to wkt otherwise the shapely polygons cannot be passed into PostGIS
            zone_name = f"Auto Zone {cluster_id + 1}"   # +1 cause for loop start count from 0 while zone ids start from 1 

            # 5. Upsert updated zone geometries into PostGIS
            upsert_query = """
                INSERT INTO zones (name, status, boundary)
                VALUES (%s, 'Active', ST_GeomFromText(%s, 4326))
                ON CONFLICT (name) DO UPDATE 
                SET boundary = EXCLUDED.boundary, status = 'Active';
            """
            # ON CONFLICT (name) DO UPDATE: tells SQL to instead of throwing an error when the zone name already exist just do an update instead of an insert, hence the name UPSERT (update + insert)
            # SET boundary = EXCLUDED.boundary: tells SQL to take the boundary value from its temporary 'EXCLUDED' table (created by SQL during an upsert) and let that be the new boundary value 

            cursor.execute(upsert_query, (zone_name, wkt_polygon))

        # 6. Re-evaluate undelivered packages 
        """
        This is needed because the trigger for the new zone and warehouse allocations only happens when a package has its destination in the packages table updated. Without this reassignment query, the undelivered packages would still be tied to the old zone and warehouse which would be wrong)
        """
        
        print("Re-evaluating pending package assignments against all new zone boundaries...")

        reassign_query = """
            UPDATE packages 
            SET destination = destination
            WHERE status = 'Pending';
        """

        cursor.execute(reassign_query)

        conn.commit()
        print(f"Successfully updated {num_zones} zone boundaries in NetGeo ({mode.upper()} mode completed).")

    except Exception as e:  # Catches any unexpected errors that occur in the try block to prevent the script from abruptly terminating. Subsequently, it assigns the error to the varible e 
        conn.rollback()
        print(f"Error executing zone automation: {e}")
    finally:
        cursor.close()
        conn.close()


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="NetGeo Dynamic Spatial Zone Clustering")
    parser.add_argument(
        "mode",
        nargs="?",
        default="adjust",
        choices=["adjust", "rebalance"],
        help="Execution mode: 'adjust' (incremental warm-start) or 'rebalance' (full K-Means overhaul)"
    )
    args = parser.parse_args()
    auto_generate_zones(mode=args.mode)
