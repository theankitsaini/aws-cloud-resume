import json
import boto3

# Explicitly bind the client and target resource
dynamodb = boto3.resource('dynamodb', region_name='eu-west-1')
table = dynamodb.Table('visitor-count-table')

def lambda_handler(event, context):
    try:
        # Atomic SET expression: If views attribute doesn't exist, it defaults to 0 and adds 1
        response = table.update_item(
            Key={'id': 'total_visitors'},
            UpdateExpression="SET #v = if_not_exists(#v, :zero) + :inc",
            ExpressionAttributeNames={'#v': 'views'},
            ExpressionAttributeValues={
                ':inc': 1,
                ':zero': 0
            },
            ReturnValues="UPDATED_NEW"
        )
        
        # Safely parse out the numeric attribute payload
        views = int(response['Attributes']['views'])
        
        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Methods': 'GET,OPTIONS'
            },
            'body': json.dumps({'count': views})
        }
        
    except Exception as e:
        print(f"Execution Error Logged: {str(e)}")
        # If database fails, return a distinct error structure
        return {
            'statusCode': 500,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Methods': 'GET,OPTIONS'
            },
            'body': json.dumps({'count': 'Error Parsing Data', 'debug': str(e)})
        }
