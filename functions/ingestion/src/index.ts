import {
  APIGatewayProxyEvent,
  APIGatewayProxyResult
} from 'aws-lambda';

// Default starter
export const handler = async(
  event: APIGatewayProxyEvent
): Promise<APIGatewayProxyResult> => {
  console.log('Event : ', JSON.stringify({
    event,
  }, null, 4));
  return {
    statusCode: 200,
    body: JSON.stringify({
      message: 'success',
    }),
  }
}
