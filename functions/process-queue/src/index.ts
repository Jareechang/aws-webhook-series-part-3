import {
  APIGatewayProxyEvent,
  APIGatewayProxyResult
} from 'aws-sdk';

export const handler = async(
  event: APIGatewayProxyEvent
): Promise<APIGatewayProxyResult> => {
  console.log('event: ', JSON.stringify({
    event,
  }, null, 4));
  let responseMessage = 'default message from process queue';
  return {
    statusCode: 200,
    body: JSON.stringify({
      message: responseMessage,
    }),
  }
}
