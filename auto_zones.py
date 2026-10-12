import sys
import os
import pandas as pd     # python's main data analysis library. It organises data into structured 2d tables called dataframes i.e. spreadsheets but in python code. Think of it as a dictionary with column names as the keys and the data in each column as the value. Data in each column are stored in a list paired to its corresponding column name. Hence, the syntax is basically the same as accessing a python dictionary 
import psycopg2     # Library that helps connect Python to the SQL database 
import numpy as np
from dotenv import load_dotenv     # Loads variables from a local .env file into the environment so credentials never get hardcoded/committed
from sklearn.cluster import KMeans
from sklearn.metrics import silhouette_score
from scipy.optimize import linear_sum_assignment
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

def get_existing_zones(conn):
    """Fetches the id and center point (centroid) of every active zone from PostGIS, ordered by id."""
    query = """
        SELECT 
            id,
            ST_X(ST_Centroid(boundary)) AS longitude, 
            ST_Y(ST_Centroid(boundary)) AS latitude 
        FROM zones 
        WHERE status = 'Active'
        ORDER BY id;
    """
    df = pd.read_sql(query, conn)
    if len(df) == 0:
        return [], None
    # ids as plain python ints (pandas gives numpy ints, which psycopg2 cannot adapt)
    # centroids as a numpy array of coords, row i belongs to ids[i]
    return [int(i) for i in df['id']], df[['longitude', 'latitude']].to_numpy()
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
        score = silhouette_score(X, labels, sample_size=min(len(X), 10000), random_state=42) # sample_size: silhouette is O(n^2), so cap it at 10k points. Exact when n <= 10k # (poor clustering) -1 < SS < 1 (good clustering, packages in the same zone are very close together and different zones are far apart)

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
        existing_ids, existing_centroids = get_existing_zones(conn)

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

        # 4. Decide which existing zone row each cluster writes to, so zone ids stay stable (drivers/packages keep pointing at them)
        # ADJUST: the warm start put centroid i at existing zone i, so cluster i simply keeps zone i.
        # REBALANCE: cluster labels are arbitrary, so match each new cluster to the NEAREST old zone centre (Hungarian algorithm,
        # linear_sum_assignment) instead of by id order. Otherwise "Zone A" could jump across the map and drag its drivers along.
        # Clusters left without an old zone become new zones; old zones left without a cluster are decommissioned.
        if existing_centroids is None:
            zone_for_cluster = {}
        elif mode == "adjust":
            zone_for_cluster = {i: existing_ids[i] for i in range(num_zones)}
        else:
            new_centroids = df.groupby('cluster')[['longitude', 'latitude']].mean().sort_index().to_numpy()
            cost = np.linalg.norm(new_centroids[:, None, :] - existing_centroids[None, :, :], axis=2)   # cost[cluster][zone] = distance in degrees
            rows, cols = linear_sum_assignment(cost)    # works for rectangular matrices too (K != number of old zones)
            zone_for_cluster = {int(r): existing_ids[int(c)] for r, c in zip(rows, cols)}

        leftover_ids = [zid for zid in existing_ids if zid not in zone_for_cluster.values()]

        cursor.execute("SELECT name FROM zones;")
        taken_names = {row[0] for row in cursor.fetchall()}

        def next_zone_name():
            n = 1
            while f"Auto Zone {n}" in taken_names:
                n += 1
            name = f"Auto Zone {n}"
            taken_names.add(name)
            return name

        # 5. Construct Convex Hull Polygon Boundaries
        for cluster_id in range(num_zones):
            cluster_points = df[df['cluster'] == cluster_id]    # Internal df['cluster'] == cluster_id comapares the packages based on the 'cluster' column and generate a list of True/False booleans. The outer df[] apply the True/False mask onto the dataframe and keeps the true rows while discarding the false, essentially applying a filter to get only the rows of package data where the package comes from the specified cluster
            points = list(zip(cluster_points['longitude'], cluster_points['latitude'])) # cluster_points[] get the columns of longitude and latitude which is zipped together to form a list of tuples containing coordinates of the points in the specified zone

            if len(points) < 3:
                print(f"Cluster {cluster_id} has fewer than 3 packages. Skipping boundary update.")
                continue

            multi_point = MultiPoint(points)    # Turns the tuples of coordinates into a single spatial collection object 
            polygon_hull = multi_point.convex_hull  # Uses the convex hull algo to find the smallest convex polygon that encloses all the points in a collection, converting a MultiPoint object into a Polygon geometry object 
            if polygon_hull.geom_type != "Polygon":     # collinear points give a LineString, which the POLYGON column rejects
                print(f"Cluster {cluster_id} is degenerate (not a polygon). Skipping boundary update.")
                continue
            wkt_polygon = polygon_hull.wkt  # Need to converet to wkt otherwise the shapely polygons cannot be passed into PostGIS

            # 6. Write the zone geometry into PostGIS
            # Existing zones are UPDATED BY ID (not upserted by name), so the script never creates a second zone on top of an old one.
            # The overlap check (trg_zones_no_overlap) is deferred to COMMIT, so it only sees the final set of boundaries and
            # a new hull is never compared against a neighbour's OLD hull mid-loop.
            if cluster_id in zone_for_cluster:
                cursor.execute(
                    "UPDATE zones SET boundary = ST_GeomFromText(%s, 4326), status = 'Active' WHERE id = %s;",
                    (wkt_polygon, zone_for_cluster[cluster_id])
                )
            else:
                cursor.execute(
                    "INSERT INTO zones (name, status, boundary) VALUES (%s, 'Active', ST_GeomFromText(%s, 4326));",
                    (next_zone_name(), wkt_polygon)
                )

        # Retire zones that no longer have a cluster (REBALANCE chose a smaller K). Decommissioned zones are ignored by the overlap check
        if leftover_ids:
            cursor.execute("UPDATE zones SET status = 'Decommissioned' WHERE id = ANY(%s);", (leftover_ids,))
            print(f"Decommissioned {len(leftover_ids)} leftover zone(s): ids {leftover_ids}")

        # 7. Re-evaluate undelivered packages 
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
